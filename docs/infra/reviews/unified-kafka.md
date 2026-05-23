---
decision: 不应该做
---

# Unified Kafka Topology for ALL Infra Events

**Status**: Design proposal (unifies and supersedes `kafka-message-bus.md`)
**Date**: 2026-05-23
**Author**: boss

---

## 1. Motivation

Currently, infra event pipelines are fragmented across four independent mechanisms:

| Producer | Current Pipeline | Buffer | Schema | CK Sink |
|----------|-----------------|--------|--------|---------|
| **cc-connect** | Docker logs -> Vector -> CK | None | Ad-hoc per event type | Yes (`cc.message_log`) |
| **patrol agents** | Inline heartbeat -> Feishu / nowhere | None | None (lost on restart) | No |
| **Docker events** | docker-events-watcher -> HTTP POST -> CK | None | Unstructured JSON | Yes (`infra.docker_events`) |
| **sing-box** | Vector + poller -> HTTP POST -> CK | None | Ad-hoc per table | Yes (`net.*`) |
| **Claude hooks** | Hook script -> HTTP POST -> CK | None | Claude event schema | Yes (`kyb.claude_hook_events`) |
| **bridge hooks** | Hook execution -> (TBD) | None | None | No |

### 1.1 Problems

1. **Four separate HTTP-CK ingestion paths** -- each producer implements its own CK HTTP INSERT logic. If CK is unreachable, events are silently dropped. There is zero buffering.
2. **No replay** -- every pipeline loses events when CK is down. The only recovery is fixing CK and hoping the producer re-sends (none do).
3. **No unified schema enforcement** -- `infra.docker_events` and `net.connection_log` use totally different schemas with no shared envelope. Cross-system correlation (e.g., "did a container restart coincide with a sing-box latency spike?") requires expensive string matching.
4. **No consumer isolation** -- a slow CK write in one pipeline (e.g., Vector batching to `cc.message_log`) does not affect others today, but if CK becomes overloaded, all HTTP-based producers experience backpressure simultaneously because they all compete for the same CK HTTP endpoint.
5. **Schema drift** -- without a schema registry, producers and consumers drift independently. A producer adds a field -> CK INSERT fails (missing column) or silently drops extra fields. The incident response is manual ALTER TABLE.

### 1.2 Why Kafka Fixes All of This

A single Kafka cluster between ALL producers and ClickHouse provides:

- **Unified buffer** -- every producer writes to Kafka, not CK. CK consumes independently. CK downtime => consumer lag, zero data loss.
- **Replay** -- configurable retention (1-90 days) on every topic. Full replay from any point.
- **Shared envelope** -- same `(schema_version, source, event_type, event_time, producer, payload)` envelope across ALL topics. Cross-topic correlation by `event_time` and `source`.
- **Schema registry** -- producers register schemas, consumers fetch them. Breaking schema changes are caught at produce time, not at CK INSERT time.
- **Consumer isolation** -- each CK consumer group has its own lag. A slow consumer for `patrol.events` does not affect `cc.events` consumption.
- **Single wire protocol** -- producers use Kafka protocol (via `kcat`, `ruby-kafka`, or Vector's Kafka sink). CK connects via native Kafka Engine. No more custom HTTP endpoints.

---

## 2. Architecture

### 2.1 High-Level Topology

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        KAFKA CLUSTER (Single Redpanda)                  │
│                     host.orb.internal:9092 (Mac super-boss)            │
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │
│  │  cc.events   │  │ patrol.events│  │ docker.events│  ... per service │
│  │  p:3  r:7d   │  │  p:1  r:7d   │  │  p:1  r:7d   │                  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                  │
│         │                 │                 │                            │
│         │                 │                 │                            │
│  ┌──────┴───────┐  ┌──────┴───────┐  ┌──────┴───────┐                  │
│  │ schema       │  │ schema       │  │ schema       │                  │
│  │ v1.1         │  │ v1.0         │  │ v1.0         │                  │
│  └──────────────┘  └──────────────┘  └──────────────┘                  │
│                                                                         │
│                        Schema Registry (Apicurio)                       │
│                      host.orb.internal:8080                             │
└─────────────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      ClickHouse (host.orb.internal:8123)                 │
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                   │
│  │ Kafka Engine │  │ Kafka Engine │  │ Kafka Engine │  ... one per       │
│  │ cc.kafka_q   │  │ patrol.kf_q  │  │ infra.dkr_q  │     topic         │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                   │
│         │ (MV)            │ (MV)            │ (MV)                       │
│         ▼                 ▼                 ▼                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                   │
│  │cc.message_log│  │patrol.evt_log│  │infra.docker_events│               │
│  │ TTL 90d      │  │ TTL 90d      │  │ TTL 90d      │                   │
│  └──────────────┘  └──────────────┘  └──────────────┘                   │
└─────────────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Grafana                                             │
│  Dashboards: Message Analysis, Infra Health, Network, Hooks, Patrol     │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Components

| Component | Role | Deployment | Notes |
|-----------|------|------------|-------|
| **Redpanda** | Kafka-compatible message broker | `kyb-infra-redpanda` (single node, dev-container mode) | Kafka API compatible; all tools/libraries work |
| **Schema Registry (Apicurio)** | Schema storage & validation | `kyb-infra-schema-registry` | Apicurio in-memory mode; no PG dependency at this scale |
| **cc-connect producer** | Publishes structured events to `cc.events` | Vector -> Kafka sink (via cc-connect Docker logs) | Existing Vector instance gets Kafka output added |
| **patrol producer** | Publishes heartbeat/status to `patrol.events` | Inline via `kcat` or `ruby-kafka` | Runs inside kyb-infra-boss |
| **docker-events producer** | Publishes container lifecycle to `docker.events` | Embedded Kafka producer in watcher script | Replaces current HTTP POST to CK |
| **sing-box producer** | Publishes connection metrics to `net.events` | Vector -> Kafka sink (or inline poller -> kcat) | Replaces current HTTP POST to CK |
| **Claude hooks producer** | Publishes hook events to `hooks.events` | Hook script -> `kcat` | Replaces current HTTP POST to CK |
| **bridge hooks producer** | Publishes hook execution logs to `bridge.events` | Future | TBD |
| **ClickHouse Kafka Engine** | Consumes all topics into MergeTree tables | Native CK feature | One `Kafka` table + one MV per topic |
| **Grafana** | Dashboards on all CK tables | Existing `kyb-infra-grafana` | Same CK data source, more tables |

### 2.3 Data Flow (All Producers)

```
[Producer]
    │  publishes structured JSON with schema envelope
    │  (optionally validates against Schema Registry)
    ▼
[Redpanda: topic.events]
    │  persisted, configurable retention
    │  consumer group tracks offset per partition
    ▼
[ClickHouse: Kafka Engine table]
    │  consumes from Kafka, inserts via MATERIALIZED VIEW
    ▼
[ClickHouse: MergeTree table]
    │  TTL-based retention, indexed for query
    ▼
[Grafana dashboard]
```

---

## 3. Topic Catalog

### 3.1 Topic Naming Convention

```
<service>.events
```

Where `<service>` is the logical service name in lower-case, no hyphens:
- `cc.events` (cc-connect)
- `patrol.events`
- `docker.events` (Docker event watcher)
- `net.events` (sing-box traffic metrics)
- `hooks.events` (Claude Code hook events)
- `bridge.events` (Feishu bridge hooks -- future)
- `system.events` (catch-all for future infra components)

### 3.2 Topic Configuration Matrix

| Topic | Partitions | Retention | Cleanup Policy | Est. Volume/day | Max Lag Before Data Loss | Schema Version |
|-------|-----------|-----------|----------------|-----------------|--------------------------|----------------|
| `cc.events` | 3 | 7 days | `delete` | ~90 events, ~50 KB | 7 days | 1.1 |
| `patrol.events` | 1 | 7 days | `delete` | ~864 events, ~400 KB | 7 days | 1.0 |
| `docker.events` | 1 | 7 days | `delete` | ~50-46k events, ~20 KB-18 MB | 7 days | 1.0 |
| `net.events` | 1 | 3 days | `delete` | ~136k events, ~11 MB | 3 days | 1.0 |
| `hooks.events` | 3 | 3 days | `delete` | ~500-5000 events, ~1-10 MB | 3 days | 1.0 |
| `bridge.events` | 1 | 7 days | `delete` | TBD | 7 days | 1.0 |
| `system.events` | 1 | 3 days | `delete` | TBD | 3 days | 1.0 |

**Rationale for partition counts**:
- **3 partitions**: `cc.events` and `hooks.events` have higher throughput and benefit from parallel consumption. Partition by message key hash preserves per-key ordering (per-message for cc, per-session for hooks).
- **1 partition**: All other topics are low-volume (< 1 msg/sec). Partitioning adds no benefit and complicates consumption ordering.

**Rationale for retention periods**:
- **7 days**: High-value operational data (cc-connect messages, patrol heartbeats, Docker events, bridge hooks). If CK goes down for a week, we can replay everything.
- **3 days**: High-frequency telemetry (net.events polled every 10s, hooks.events every tool call). If CK goes down for 3 days, the data is stale anyway. Longer retention in CK (MergeTree TTL) covers historical queries.

### 3.3 Topic: `cc.events`

**Publishers**: cc-connect (via Vector -> Kafka sink)
**Subscribers**: ClickHouse Kafka Engine -> `cc.message_log`

Configuration and schema are identical to the existing design in [kafka-message-bus.md](./kafka-message-bus.md) section 3.1. See that document for full event types and payloads.

### 3.4 Topic: `patrol.events`

**Publishers**: patrol agents (via `kcat` or `ruby-kafka`)
**Subscribers**: ClickHouse Kafka Engine -> `patrol.event_log`

Configuration and schema are identical to [kafka-message-bus.md](./kafka-message-bus.md) section 3.2.

### 3.5 Topic: `docker.events`

**Publishers**: docker-event-watcher (runs in each `kyb-infra-boss`)
**Subscribers**: ClickHouse Kafka Engine -> `infra.docker_events`

**Configuration**:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Partitions | 1 | ~50 events/day per cluster (worst-case 46k with HEALTHCHECK); no parallelism needed |
| Replication factor | 1 | Single broker |
| Retention | 7 days | Match cc.events / patrol.events |
| Cleanup policy | `delete` | |

**Schema (envelope)**:

```json
{
  "schema_version": "1.0",
  "source": "docker-event-watcher",
  "event_type": "container:die | container:start | container:health_status | container:oom | ...",
  "event_time": "2026-05-23T16:38:00.000Z",
  "producer": {
    "host": "kyb-infra-boss",
    "cluster": "mac-orbstack",
    "boss_id": "boss-1"
  },
  "payload": {
    "container_name": "kyb-infra-cc-connect",
    "actor_id": "abc123def456",
    "image": "kyb-cc-connect:latest",
    "exit_code": 137,
    "health_status": "",
    "oom_killed": true,
    "restart_count": 3
  }
}
```

**Migration from current HTTP-CK pipeline**:

The existing `docker-event-watcher.sh` script currently POSTs to CK via HTTP. To migrate:
1. Add Kafka output (`kcat -P`) alongside or replacing the CK HTTP POST.
2. CK consumption switches from HTTP INSERT to Kafka Engine table.
3. During migration (dual-write), both paths run simultaneously for 24h for row count verification.

### 3.6 Topic: `net.events`

**Publishers**: sing-box Vector pipeline + sb-metrics-poller
**Subscribers**: ClickHouse Kafka Engine -> `net.connection_log`, `net.outbound_snapshot`, `net.latency`

**Configuration**:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Partitions | 1 | High-frequency but low per-event value; ordering matters for delta computation |
| Replication factor | 1 | Single broker |
| Retention | 3 days | High volume (~11 MB/day), CK TTL covers long-term analysis |
| Cleanup policy | `delete` | |

**Schema (envelope)**:

```json
{
  "schema_version": "1.0",
  "source": "sing-box",
  "event_type": "connection_close | outbound_snapshot | latency_probe",
  "event_time": "2026-05-23T16:38:00.000Z",
  "producer": {
    "host": "kyb-infra-boss",
    "instance": "kyb-infra-sing-box"
  },
  "payload": {
    "outbound_tag": "Relay-JP1",
    "network": "tcp",
    "destination": "8.8.8.8:443",
    "bytes_upload": 4096,
    "bytes_download": 65536,
    "duration_ms": 9876,
    "rule_tag": "ai-sites",
    "active_connections": 3,
    "latency_ms": 42
    // event-type-specific fields
  }
}
```

**Key design decision**: All three sing-box data types (`connection_close`, `outbound_snapshot`, `latency_probe`) share ONE topic (`net.events`) differentiated by `event_type`. This keeps the topic count manageable and allows ordering correlation (e.g., "which snapshot was current when this connection closed?"). Each event type maps to a different CK table via MATERIALIZED VIEW filtering on `event_type`.

```sql
-- Kafka Engine table (single, consumes all net.events)
CREATE TABLE net.kafka_queue ( ... ) ENGINE = Kafka SETTINGS kafka_topic_list = 'net.events';

-- Materialized Views route by event_type
CREATE MATERIALIZED VIEW net.kafka_to_connection_log TO net.connection_log AS
SELECT * FROM net.kafka_queue WHERE event_type = 'connection_close';

CREATE MATERIALIZED VIEW net.kafka_to_outbound_snapshot TO net.outbound_snapshot AS
SELECT * FROM net.kafka_queue WHERE event_type = 'outbound_snapshot';

CREATE MATERIALIZED VIEW net.kafka_to_latency TO net.latency AS
SELECT * FROM net.kafka_queue WHERE event_type = 'latency_probe';
```

### 3.7 Topic: `hooks.events`

**Publishers**: Claude Code hook script (`emit-ck.sh`)
**Subscribers**: ClickHouse Kafka Engine -> `kyb.claude_hook_events`

**Configuration**:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Partitions | 3 | Higher throughput than other topics; parallel consumption per session |
| Replication factor | 1 | Single broker |
| Retention | 3 days | High event volume, CK TTL covers long-term queries |
| Cleanup policy | `delete` | |

**Schema (envelope)**:

```json
{
  "schema_version": "1.0",
  "source": "claude-hooks",
  "event_type": "PostToolUse | SessionStart | SessionEnd | Stop | ...",
  "event_time": "2026-05-23T16:38:00.000Z",
  "producer": {
    "host": "kyb-infra-boss",
    "session_id": "sess_abc123",
    "agent_id": "main"
  },
  "payload": {
    "tool_name": "Bash",
    "tool_input": "git status",
    "tool_output": "...",
    "tool_exit_code": 0,
    "duration_ms": 150,
    "cwd": "/home/dev/projects/kyb",
    "project": "kyb",
    "claude_version": "0.3.2",
    "model": "deepseek-v4-flash",
    // ... other fields from existing hooks schema
  }
}
```

**Migration from current HTTP-CK pipeline**:

The existing `emit-ck.sh` script currently POSTs to CK via HTTP `--noproxy '*'`. To migrate:
1. Replace the `curl` to CK with `kcat -P -b host.orb.internal:9092 -t hooks.events`.
2. Create `kyb.kafka_hooks_queue` Kafka Engine table.
3. Create MATERIALIZED VIEW targeting `kyb.claude_hook_events`.
4. Run dual-write during migration to verify row counts match.

**Important**: The hook script is fail-open (exits 0 on failure). The `kcat` invocation must also be fail-open:
```bash
echo "$enriched_json" | kcat -P -b host.orb.internal:9092 -t hooks.events -T 2>/dev/null || true
```

### 3.8 Topic: `bridge.events` (Future)

**Publishers**: Feishu bridge hooks (cc-cron results, session lifecycle, hook execution logs)
**Subscribers**: ClickHouse Kafka Engine -> (TBD)

**Configuration**:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Partitions | 1 | Low volume |
| Retention | 7 days | Operational data, valuable for debugging |
| Cleanup policy | `delete` | |

### 3.9 Topic: `system.events` (Future)

**Publishers**: Healthchecks, cc-cron, boss lifecycle, any infra component without a dedicated topic
**Subscribers**: ClickHouse Kafka Engine -> (TBD, likely `system.event_log`)

**Configuration**: Same as `bridge.events`. A catch-all for events that do not belong to any other topic.

---

## 4. Schema Registry

### 4.1 Why Schema Registry

Without schema registry, schema drift causes silent data loss:
- A producer adds a field -> CK INSERT ignores extra columns (no error) or fails (missing column).
- A producer changes a field type -> CK INSERT fails with type mismatch.
- A producer removes a field -> CK column receives NULL (may break downstream queries).
- No version tracking -> you cannot tell which schema a historical event used.

### 4.2 Choice: Apicurio Schema Registry

| Factor | Apicurio | Confluent SR |
|--------|----------|--------------|
| Resource usage | Lightweight (Quarkus), ~128 MB | Heavy (JVM), ~256 MB |
| Startup time | <5 seconds | ~30 seconds |
| Dependencies | None (in-memory mode) | Kafka (uses Kafka topics for state) |
| API compatibility | Confluent-compatible + own API | Native |
| Serializers | JSON, Avro, Protobuf, AsyncAPI | Avro, JSON, Protobuf |
| In-memory mode | Yes (no PG/Kafka dependency) | No (requires Kafka topic) |

**Recommendation**: **Apicurio in-memory schema registry**. At our scale (< 50 schemas), in-memory storage is sufficient. The registry state is ephemeral (lost on restart), but schemas are versioned in git and re-register on startup.

Deployment:

```bash
docker run -d \
  --name kyb-infra-schema-registry \
  --restart unless-stopped \
  --network kyb-infra \
  -p 8080:8080 \
  apicurio/apicurio-registry-mem:latest
```

### 4.3 Schema Format: JSON Schema (v2020-12)

All producers use JSON as the serialization format. JSON Schema provides:
- **Validation** -- producers can validate before producing (optional, recommended for development).
- **Documentation** -- schemas are self-describing with `description` fields.
- **Evolution** -- `$ref` and `definitions` support shared types across topics.

**Envelope schema** (registered once, referenced by all topic-specific schemas):

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://kyb.dev/schemas/envelope/v1.json",
  "title": "Kafka Event Envelope",
  "description": "Shared envelope for all infra Kafka events",
  "type": "object",
  "required": ["schema_version", "source", "event_type", "event_time", "producer", "payload"],
  "properties": {
    "schema_version": {
      "type": "string",
      "description": "Envelope schema version (semver)",
      "examples": ["1.0"]
    },
    "source": {
      "type": "string",
      "description": "Producer service name",
      "examples": ["cc-connect", "patrol", "docker-event-watcher", "sing-box", "claude-hooks"]
    },
    "event_type": {
      "type": "string",
      "description": "Specific event type within the source's domain"
    },
    "event_time": {
      "type": "string",
      "format": "date-time",
      "description": "When the event occurred on the producer (ISO-8601, ms precision)"
    },
    "producer": {
      "type": "object",
      "description": "Producer identity metadata",
      "required": ["host"],
      "properties": {
        "host": { "type": "string", "description": "Hostname of the producer" },
        "instance": { "type": "string", "description": "Container or process name" },
        "cluster": { "type": "string", "description": "Cluster name (multi-cluster deployments)" },
        "patrol_id": { "type": "string" },
        "session_id": { "type": "string" },
        "boss_id": { "type": "string" }
      }
    },
    "payload": {
      "type": "object",
      "description": "Event-type-specific data. Schema validation per event_type via $ref."
    }
  }
}
```

### 4.4 Schema Registration Workflow

1. **Develop** -- Write new JSON Schema in `docs/infra/schemas/<topic>-<event_type>.json`.
2. **Register** -- POST to Apicurio API on startup or deployment.
3. **Validate** -- Producers optionally validate before publishing. CK does NOT validate (avoids consumption overhead).
4. **Evolve** -- Backward-compatible changes (adding optional fields) increment minor version. Breaking changes (removing/renaming fields) create a new schema version with a new `event_type` or topic.
5. **Deprecate** -- Old schema versions remain in registry for historical queries. CK tables can handle multiple schema versions via nullable columns.

**Registration script** (runs at Redpanda startup via init container or boot script):

```bash
#!/bin/bash
# register-schemas.sh — register all JSON schemas with Apicurio

SCHEMA_REGISTRY="http://host.orb.internal:8080/apis/registry/v2"

for schema_file in /etc/kyb/schemas/*.json; do
  group=$(basename "$schema_file" .json | cut -d'-' -f1)
  artifact_id=$(basename "$schema_file" .json)

  curl -s -X POST "$SCHEMA_REGISTRY/groups/$group/artifacts" \
    -H "Content-Type: application/json" \
    -d "{
      \"artifactId\": \"$artifact_id\",
      \"type\": \"JSON\",
      \"content\": $(cat "$schema_file" | jq -Rs '.')
    }"
  echo "Registered: $group/$artifact_id"
done
```

### 4.5 Schema Location in Repo

Schemas live in `docs/infra/schemas/` (one file per topic-event-type):

```
docs/infra/schemas/
├── envelope-v1.json              # Shared envelope (referenced by all)
├── cc-message_received-v1.json
├── cc-turn_complete-v1.json
├── cc-permission_request-v1.json
├── patrol-heartbeat-v1.json
├── patrol-anomaly-v1.json
├── docker-container_die-v1.json
├── docker-container_start-v1.json
├── docker-health_status-v1.json
├── net-connection_close-v1.json
├── net-outbound_snapshot-v1.json
├── net-latency_probe-v1.json
├── hooks-PostToolUse-v1.json
├── hooks-SessionStart-v1.json
├── hooks-SessionEnd-v1.json
└── hooks-Stop-v1.json
```

---

## 5. ClickHouse Kafka Engine Integration

### 5.1 Principle: One Kafka Engine Table Per Topic, One MV Per Target Table

Every topic has:
1. A `kafka_queue` table (consumes raw JSON from Kafka)
2. One or more `MATERIALIZED VIEW`s (route to target MergeTree tables)

Target tables retain their existing schemas from the current designs. The only change is the ingestion path: HTTP POST -> Kafka Engine.

### 5.2 Kafka Engine Tables (Skeleton)

```sql
-- cc.events
CREATE TABLE cc.kafka_queue (
    schema_version  String,
    source          String,
    event_type      String,
    event_time      DateTime64(3),
    producer_host   String,
    producer_instance String,
    payload         String    -- full JSON payload as raw string
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'cc.events',
    kafka_group_name = 'ck-consumer-cc',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3;
```

```sql
-- docker.events
CREATE TABLE infra.kafka_docker_events (
    schema_version  String,
    source          String,
    event_type      String,
    event_time      DateTime64(3),
    producer_host   String,
    producer_cluster String,
    producer_boss_id String,
    payload         String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'docker.events',
    kafka_group_name = 'ck-consumer-docker',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;
```

```sql
-- net.events (single queue → three MVs)
CREATE TABLE net.kafka_queue (
    schema_version  String,
    source          String,
    event_type      String,
    event_time      DateTime64(3),
    producer_host   String,
    producer_instance String,
    payload         String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'net.events',
    kafka_group_name = 'ck-consumer-net',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;
```

```sql
-- hooks.events
CREATE TABLE kyb.kafka_hooks_queue (
    schema_version  String,
    source          String,
    event_type      String,
    event_time      DateTime64(3),
    producer_host   String,
    producer_session_id String,
    producer_agent_id String,
    payload         String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'hooks.events',
    kafka_group_name = 'ck-consumer-hooks',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3;
```

### 5.3 Materialized Views: Envelope Flattening Strategy

Two strategies for handling the shared envelope + JSON payload:

**Strategy A (Recommended): Flat columns + payload_raw**

The Kafka Engine table extracts top-level envelope fields into columns. The `payload` field remains as a raw JSON string. MATERIALIZED VIEWs parse `payload` for target-specific columns and forward to the MergeTree table.

```sql
CREATE MATERIALIZED VIEW cc.kafka_to_message_log TO cc.message_log AS
SELECT
    event_time,
    source,
    event_type,
    -- Parse payload JSON for cc-specific fields
    JSONExtractString(payload, 'msg_id') AS msg_id,
    JSONExtractString(payload, 'session') AS session,
    -- ... other fields
    payload AS payload_raw  -- store original for forward compatibility
FROM cc.kafka_queue;
```

**Strategy B (Simpler): JSONExtract at query time**

Store the entire event as-is in a single `event_json` String column. Extract fields at query time via `JSONExtract`. This is simpler but slower for frequent queries.

**Recommendation**: Strategy A for `cc.events` and `patrol.events` (heavily queried). Strategy B as a fallback for `docker.events` and `net.events` (rarely queried, or query patterns are simple).

### 5.4 Dead Letter Queue

The Kafka Engine silently skips messages that fail to parse (e.g., malformed JSON, schema violation). To capture these:

```sql
CREATE TABLE infra.kafka_dlq (
    topic         String,
    partition     Int32,
    offset        Int64,
    raw_message   String,
    error         String,
    failed_at     DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY failed_at;
```

Messages that fail in the Kafka Engine consumption can be captured by setting `kafka_handle_error_mode='default'` (CK tracks them in `system.kafka_errors`). For simpler operation, each producer also publishes to `<topic>.dlq` if its own local validation fails.

At current volume (~1000 events/day total across all topics), manual DLQ review once per week is sufficient.

---

## 6. Retention Policy Framework

### 6.1 Three-Tier Retention

| Tier | Kafka Retention | CK TTL | Description | Topics |
|------|----------------|--------|-------------|--------|
| **Hot** | 7 days | 90 days | Operational data, frequent queries | `cc.events`, `patrol.events`, `docker.events`, `bridge.events` |
| **Warm** | 3 days | 30 days | High-frequency telemetry, moderate query frequency | `net.events`, `hooks.events` |
| **Cold** | 3 days | 90 days | Catch-all, sparse queries | `system.events` |

**Why Kafka retention != CK TTL**:

- **Kafka retention** determines replay window. If CK goes down for longer than Kafka retention, some events are unrecoverable. Hot topics get 7 days to cover the maximum expected CK downtime.
- **CK TTL** determines historical query window. CK is much cheaper per GB than Kafka for long-term storage. 90 days covers quarterly reviews and incident post-mortems.

### 6.2 Storage Estimates

| Topic | Daily Volume | Kafka 7d | CK 90d |
|-------|-------------|----------|--------|
| cc.events | 50 KB | 350 KB | 4.5 MB |
| patrol.events | 400 KB | 2.8 MB | 36 MB |
| docker.events | 20 KB (no HC) / 18 MB (with HC) | 140 KB / 126 MB | 1.8 MB / 1.6 GB |
| net.events | 11 MB | 33 MB (3d) | 330 MB |
| hooks.events | 5 MB | 15 MB (3d) | 150 MB |
| **Total** | **~17 MB / ~35 MB (with HC)** | **~37 MB / ~177 MB** | **~522 MB / ~2.1 GB** |

**Notes**:
- Docker events with HEALTHCHECK enabled on all containers dominates storage. Without it, total storage is < 1 GB over 90 days.
- At current scale (no HEALTHCHECK on most containers), total CK storage is ~500 MB.
- Kafka disk usage is dominated by `net.events` and `hooks.events` at ~48 MB combined for their retention periods.

### 6.3 Kafka Retention Configuration

```bash
# Hot tier (7 days)
rpk topic alter-config cc.events --set retention.ms=604800000
rpk topic alter-config patrol.events --set retention.ms=604800000
rpk topic alter-config docker.events --set retention.ms=604800000
rpk topic alter-config bridge.events --set retention.ms=604800000

# Warm tier (3 days)
rpk topic alter-config net.events --set retention.ms=259200000
rpk topic alter-config hooks.events --set retention.ms=259200000
rpk topic alter-config system.events --set retention.ms=259200000
```

### 6.4 CK TTL Configuration

```sql
-- cc.message_log: 90 days
ALTER TABLE cc.message_log MODIFY TTL event_time + INTERVAL 90 DAY;

-- patrol.event_log: 90 days
ALTER TABLE patrol.event_log MODIFY TTL event_time + INTERVAL 90 DAY;

-- infra.docker_events: 90 days
ALTER TABLE infra.docker_events MODIFY TTL event_time + INTERVAL 90 DAY;

-- net.connection_log: 30 days
ALTER TABLE net.connection_log MODIFY TTL event_time + INTERVAL 30 DAY;

-- net.outbound_snapshot: 7 days (high-frequency, quickly outdated)
ALTER TABLE net.outbound_snapshot MODIFY TTL event_time + INTERVAL 7 DAY;

-- net.latency: 90 days (useful for long-term trend analysis)
ALTER TABLE net.latency MODIFY TTL event_time + INTERVAL 90 DAY;

-- kyb.claude_hook_events: 30 days
ALTER TABLE kyb.claude_hook_events MODIFY TTL toDate(timestamp) + INTERVAL 30 DAY;
```

---

## 7. Kafka Deployment

### 7.1 Redpanda (Same as Existing Design)

Uses the Redpanda deployment from [kafka-message-bus.md](./kafka-message-bus.md) section 6.2. No changes needed except adding the Schema Registry container.

### 7.2 Schema Registry Deployment

```bash
docker run -d \
  --name kyb-infra-schema-registry \
  --restart unless-stopped \
  --network kyb-infra \
  -p 8080:8080 \
  apicurio/apicurio-registry-mem:latest
```

### 7.3 Topic Creation Script

```bash
#!/bin/bash
# create-infra-topics.sh — run once at cluster bootstrap

# Hot tier (7d)
rpk topic create cc.events --partitions 3
rpk topic alter-config cc.events --set retention.ms=604800000

rpk topic create patrol.events --partitions 1
rpk topic alter-config patrol.events --set retention.ms=604800000

rpk topic create docker.events --partitions 1
rpk topic alter-config docker.events --set retention.ms=604800000

rpk topic create bridge.events --partitions 1
rpk topic alter-config bridge.events --set retention.ms=604800000

# Warm tier (3d)
rpk topic create net.events --partitions 1
rpk topic alter-config net.events --set retention.ms=259200000

rpk topic create hooks.events --partitions 3
rpk topic alter-config hooks.events --set retention.ms=259200000

rpk topic create system.events --partitions 1
rpk topic alter-config system.events --set retention.ms=259200000

# DLQ topics (one per producer, retention 30 days for debugging)
rpk topic create cc.dlq --partitions 1
rpk topic create docker.dlq --partitions 1
rpk topic create hooks.dlq --partitions 1
rpk topic create net.dlq --partitions 1

echo "All topics created."
rpk topic list
```

### 7.4 Resource Estimates

| Container | CPU | Memory | Disk |
|-----------|-----|--------|------|
| Redpanda | < 0.1 core | ~256 MB | ~200 MB (90d data) + ~150 MB (image) |
| Schema Registry | < 0.05 core | ~128 MB | ~100 MB (image) |
| **Total** | **< 0.15 core** | **~384 MB** | **~450 MB** |

These are negligible additions to the existing infra footprint.

---

## 8. Producer Migration Plan

### 8.1 Migration Phases

#### Phase 1: Deploy Infrastructure (Day 1)

1. Deploy Redpanda (already exists from `kafka-message-bus.md`).
2. Deploy Apicurio Schema Registry.
3. Create all topics via `create-infra-topics.sh`.
4. Register all schemas via `register-schemas.sh`.
5. No producers changed yet. Existing HTTP-CK pipelines continue.

#### Phase 2: Migrate cc-connect (Day 1-2)

1. Add Kafka output to existing Vector config alongside current CK output (dual-write).
2. Create `cc.kafka_queue` + MATERIALIZED VIEW in ClickHouse.
3. Verify row counts match between direct CK and Kafka-sourced CK after 24h.
4. Remove Vector's direct CK output. cc-connect now uses Kafka only.

#### Phase 3: Migrate patrol (Day 2)

1. Switch patrol producer from `kcat -> CK (not implemented yet)` to `kcat -> Kafka -> CK`.
2. Current patrol events are not persisted anywhere; this is the first persistence.

#### Phase 4: Migrate Docker events (Day 2-3)

1. Add `kcat` output to `docker-event-watcher.sh` alongside the HTTP CK output (dual-write).
2. Create `infra.kafka_docker_events` + MATERIALIZED VIEW.
3. Verify row counts after 24h.
4. Remove HTTP CK output from watcher script.

#### Phase 5: Migrate sing-box (Day 3-4)

1. Switch Vector's sing-box output from CK HTTP to Kafka topic `net.events`.
2. Switch `sb-metrics-poller` from HTTP CK to `kcat -> net.events`.
3. Create `net.kafka_queue` + three MATERIALIZED VIEWs.
4. Verify row counts after 24h.

#### Phase 6: Migrate Claude hooks (Day 4-5)

1. Modify `emit-ck.sh` to publish to `hooks.events` via `kcat` alongside HTTP CK (dual-write).
2. Create `kyb.kafka_hooks_queue` + MATERIALIZED VIEW.
3. Verify row counts after 24h.
4. Remove HTTP CK output from hook script.

**Important**: The hook script is time-sensitive (5s timeout). `kcat` invocation must be fast and fail-open:
```bash
echo "$payload" | kcat -P -b host.orb.internal:9092 -t hooks.events -T 2>/dev/null || true
```

#### Phase 7: Cleanup (Day 5-6)

1. Remove all HTTP CK ingestion code from producers.
2. Remove Vector's direct CK sinks (keep Vector only as log parser/shipper to Kafka).
3. Document the final topology in runbook.
4. Add Kafka consumer lag monitoring to Grafana.

### 8.2 Dual-Write Verification

During each migration phase, run both pipelines (HTTP-CK + Kafka-CK) simultaneously and compare:

```sql
-- Compare row counts for cc.message_log
SELECT 'http' AS source, count() FROM cc.message_log
WHERE event_time > now() - INTERVAL 1 HOUR
UNION ALL
SELECT 'kafka' AS source, count() FROM cc.message_log_kafka  -- temporary table for Kafka-sourced data
WHERE event_time > now() - INTERVAL 1 HOUR;
```

Row counts should match within 0.1% (allowing for exactly-once semantics differences). If they diverge, investigate before cutting over.

---

## 9. Failure Modes and Recovery

### 9.1 Failure Matrix

| Failure | Effect | Recovery |
|---------|--------|----------|
| **Redpanda broker down** | All producers fail to publish. Events are lost during downtime. | Restart container. Events during downtime are lost (producers have no local buffer). Mitigation: `kyb-infra-redpanda` has `--restart unless-stopped`. |
| **CK down** | All Kafka consumer groups pause. Events accumulate in topics up to retention limit. | Restart CK. Kafka consumers resume from committed offset. **No data loss within retention window.** |
| **Schema Registry down** | Schema validation unavailable. Producers should skip validation (fail-open) and publish anyway. | Restart container. Schemas are re-registered on startup from git. |
| **Kafka volume full** | Producers fail. CK consumer cannot commit offsets. | Increase disk or reduce retention. Alert on disk usage > 80%. |
| **Producer bug (spam)** | One producer floods its topic. Other topics unaffected (consumer isolation). CK consumer may fall behind on the flooded topic. | Investigate producer. Drop topic or reset consumer offset. DLQ captures malformed messages. |
| **Network partition** | Producers cannot reach Kafka. Events lost during partition. | Reconnect. No buffer on producer side. |
| **Permanent CK data loss** | CK volume destroyed. | Replay all events from Kafka (within retention window). Then recreate CK tables from scratch. |

### 9.2 Operational Runbooks

**Redpanda down**:
```bash
# Restart
docker restart kyb-infra-redpanda

# Check health
rpk cluster health

# Check consumer groups
rpk group list
rpk group describe ck-consumer-cc --print
```

**CK consumer lag**:
```sql
SELECT * FROM system.kafka_consumer_lag;
```

If lag grows beyond retention window, increase `kafka_num_consumers` or add partitions.

**Schema Registry lost**:
```bash
# Re-register from git
cd docs/infra/schemas && ./register-schemas.sh
```

---

## 10. Monitoring the Kafka Bus

### 10.1 Key Metrics

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| Consumer lag (per group) | Redpanda `/metrics` | > 10k messages for > 5 minutes |
| Broker disk usage | Redpanda `/metrics` | > 80% |
| Producer error rate | Redpanda `/metrics` | > 0 for 5 minutes |
| Schema Registry health | Apicurio `/health` | Non-200 for 2 consecutive probes |
| CK consumption rate | `system.kafka_consumer_lag` | Zero for 5 minutes = CK consumer stopped |

### 10.2 Grafana Dashboard: "Kafka Bus"

Recommended panels:

1. **Message Rate by Topic** (time series, stacked) -- `rpk topic list` or Redpanda metrics
2. **Consumer Lag by Group** (time series) -- per-consumer-group lag
3. **Broker Disk Usage** (gauge) -- current usage %
4. **Schema Registry Health** (single stat) -- up/down
5. **DLQ Count** (single stat) -- total messages in all DLQ topics
6. **Topic Storage** (table) -- per-topic storage estimate

### 10.3 Patrol Integration

Add Kafka health checks to the patrol check list:

```bash
# In patrol heartbeat:
kafka_checks:
  redpanda_running: true     # docker ps check
  topic_count: 7             # expected topic count
  schema_registry: true      # http://host.orb.internal:8080/health
  ck_consumer_lag_cc: 0      # from SQL
  ck_consumer_lag_patrol: 0  # from SQL
  ck_consumer_lag_net: 0     # from SQL
  ck_consumer_lag_hooks: 0   # from SQL
```

---

## 11. Super-Boss → Remote Boss Kafka Architecture

### 11.1 The Challenge

Currently, CK is centralized on Mac/Orbstack (super-boss). Remote clusters (Aliyun, Office) send events via HTTP POST to the super-boss CK. With Kafka, remote producers could:

1. **Publish to local Redpanda** (each cluster runs its own Redpanda) -> CK syncs between clusters (complex, overkill).
2. **Publish directly to super-boss Kafka** (via Tailscale) -> simpler, but introduces network dependency.
3. **Publish to local CK via HTTP** (keep current path for remote clusters, add Kafka only for Mac).

### 11.2 Recommendation

For now (Phase 1-6): **Publish only to the Mac/Orbstack super-boss Kafka**. Remote clusters continue using the existing HTTP POST to Mac CK.

Long-term: If remote cluster event volume grows, deploy a lightweight Redpanda + Schema Registry per remote cluster. The remote Redpanda can mirror events to super-boss via Kafka MirrorMaker 2 or simply be consumed independently.

**Why NOT MirrorMaker now**: The super-boss Redpanda is already consuming from the same CK. Remote events that arrive via HTTP POST are stored in the same CK tables. Adding MirrorMaker today adds operational complexity for zero benefit at current scale.

---

## 12. Verdict

### What Changed vs. Existing Design (`kafka-message-bus.md`)

| Aspect | kafka-message-bus.md | This Design |
|--------|---------------------|-------------|
| Scope | cc-connect + patrol only | **ALL** infra producers (cc, patrol, docker, sing-box, hooks, bridge, system) |
| Schema Registry | Not addressed | **Added**: Apicurio in-memory, JSON Schema, git-stored schemas |
| Retention policies | One-size-fits-all (7d) | **Three-tier**: hot (7d), warm (3d), cold (3d) + CK TTL per table |
| CK integration | One topic = one table | **Unified**: all topics consumed via Kafka Engine; DLQ for error capture |
| Migration plan | 3 phases | **7 phases** with dual-write verification per producer |
| Multi-cluster | Not addressed | **Documented**: remote clusters keep HTTP-CK for now |
| Failure modes | 4 scenarios | **Complete matrix**: broker down, CK down, SR down, disk full, producer spam, network partition |

### Key Design Decisions

1. **One cluster, one schema registry, one CK sink** -- Simplicity over scale. At < 1 MB/day, a single-node Redpanda is sufficient for years.
2. **Shared envelope across all topics** -- Enables cross-system correlation without table joins.
3. **Topic per service, not per event type** -- Keeps topic count manageable (7 topics vs. 20+). Event type differentiation within topic via `event_type` field.
4. **Apicurio over Confluent SR** -- In-memory mode means zero external dependencies. At < 50 schemas, this is the right tradeoff.
5. **Dual-write migration** -- Every producer migrates with full verification before cutover. Zero risk.
6. **Remote clusters NOT migrated to Kafka** -- They continue HTTP-CK. Kafka is a Mac super-boss optimization. Remote clusters lack the volume to justify Kafka.

### Implementation Summary

```
Phase 1: Deploy SR + topics + schemas           [Day 1, ~30 min]
Phase 2: Migrate cc-connect                      [Day 1-2, ~4h incl. verification]
Phase 3: Migrate patrol                          [Day 2, ~1h]
Phase 4: Migrate Docker events                   [Day 2-3, ~2h]
Phase 5: Migrate sing-box                        [Day 3-4, ~3h]
Phase 6: Migrate Claude hooks                    [Day 4-5, ~2h]
Phase 7: Cleanup + documentation                 [Day 5-6, ~2h]
```

**Total effort**: ~5-6 days of calendar time, ~15h of actual work.

---

## 13. Appendices

### A. Quick Start (New Machine)

```bash
# 1. Start Redpanda (if not already running)
docker run -d --name kyb-infra-redpanda \
  --restart unless-stopped \
  --network kyb-infra \
  -p 9092:9092 -p 9644:9644 \
  -v kafka_data:/var/lib/redpanda/data \
  docker.redpanda.com/redpandadata/redpanda:latest \
  redpanda start --mode dev-container \
    --kafka-addr PLAINTEXT://0.0.0.0:9092 \
    --advertise-kafka-addr PLAINTEXT://host.orb.internal:9092

# 2. Start Schema Registry
docker run -d \
  --name kyb-infra-schema-registry \
  --restart unless-stopped \
  --network kyb-infra \
  -p 8080:8080 \
  apicurio/apicurio-registry-mem:latest

# 3. Create topics
./create-infra-topics.sh

# 4. Register schemas
./register-schemas.sh

# 5. Verify
rpk topic list
curl http://host.orb.internal:8080/apis/registry/v2/search/artifacts
```

### B. Full ClickHouse DDL

```sql
-- cc.events
CREATE TABLE cc.kafka_queue (...);
CREATE MATERIALIZED VIEW cc.kafka_to_message_log TO cc.message_log AS ...;

-- patrol.events
CREATE TABLE patrol.kafka_queue (...);
CREATE MATERIALIZED VIEW patrol.kafka_to_event_log TO patrol.event_log AS ...;

-- docker.events
CREATE TABLE infra.kafka_docker_events (...);
CREATE MATERIALIZED VIEW infra.kafka_to_docker_events TO infra.docker_events AS ...;

-- net.events (one queue, three MVs)
CREATE TABLE net.kafka_queue (...);
CREATE MATERIALIZED VIEW net.kafka_to_connection_log TO net.connection_log AS ...;
CREATE MATERIALIZED VIEW net.kafka_to_outbound_snapshot TO net.outbound_snapshot AS ...;
CREATE MATERIALIZED VIEW net.kafka_to_latency TO net.latency AS ...;

-- hooks.events
CREATE TABLE kyb.kafka_hooks_queue (...);
CREATE MATERIALIZED VIEW kyb.kafka_to_claude_hooks TO kyb.claude_hook_events AS ...;
```

### C. Producer Changes Summary

| Producer | Current | Migration Target | Dual-Write Path |
|----------|---------|-----------------|-----------------|
| **cc-connect (Vector)** | Vector -> CK | Vector -> Kafka `cc.events` -> CK | Vector Kafka sink + CK sink simultaneously |
| **patrol** | Nowhere (lost) | `kcat -> patrol.events` -> CK | N/A (first persistence) |
| **docker-event-watcher** | curl -> CK HTTP | `kcat -> docker.events` -> CK | curl + kcat simultaneously |
| **sing-box (Vector)** | Vector -> CK | Vector -> Kafka `net.events` -> CK | Vector Kafka sink + CK sink simultaneously |
| **sb-metrics-poller** | HTTP POST -> CK | `kcat -> net.events` -> CK | HTTP + kcat simultaneously |
| **claude-hooks (emit-ck.sh)** | curl -> CK HTTP | `kcat -> hooks.events` -> CK | curl + kcat simultaneously |

### D. Schema Registration Script (register-schemas.sh)

```bash
#!/bin/bash
# register-schemas.sh — register all JSON schemas with Apicurio

set -euo pipefail

SR_URL="${SCHEMA_REGISTRY_URL:-http://host.orb.internal:8080/apis/registry/v2}"
SCHEMA_DIR="${SCHEMA_DIR:-/etc/kyb/schemas}"

echo "Registering schemas from $SCHEMA_DIR to $SR_URL"

for schema_file in "$SCHEMA_DIR"/*.json; do
  [ -f "$schema_file" ] || continue
  artifact_id=$(basename "$schema_file" .json)
  group=$(echo "$artifact_id" | cut -d- -f1)
  echo "  Registering $group/$artifact_id ..."

  response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SR_URL/groups/$group/artifacts" \
    -H "Content-Type: application/json" \
    -d "{
      \"artifactId\": \"$artifact_id\",
      \"type\": \"JSON\",
      \"content\": $(cat "$schema_file" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    }")

  case "$response" in
    200|201) echo "  ✓ $artifact_id registered" ;;
    409)    echo "  ∼ $artifact_id already exists (version conflict — skipping)" ;;
    *)      echo "  ✗ $artifact_id failed (HTTP $response)" ;;
  esac
done

echo "Schema registration complete."
```

---

> ／人◕ ‿‿ ◕人＼
