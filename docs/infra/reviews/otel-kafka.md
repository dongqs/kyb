---
decision: 不应该做
---

# OTel + Kafka: Span Events as Kafka Messages

**Status:** Design proposal
**Date:** 2026-05-23
**Author:** boss
**Prerequisites:** `docs/infra/reviews/kafka-message-bus.md`, `docs/infra/reviews/otel-cc-connect.md`, `docs/infra/reviews/otel-patrol.md`

---

## 1. Motivation

Currently we have two independent OTel design documents (cc-connect, patrol) that propose direct OTLP export to Tempo/Jaeger for trace storage:

```
cc-connect --OTLP--> OTel Collector --> Tempo (traces)
patrol     --OTLP--> OTel Collector --> Tempo (traces)
```

And a separate Kafka message bus design for observability events (cc-connect logs, patrol heartbeats):

```
cc-connect --> Vector --> Kafka --> CK Kafka Engine --> MergeTree
patrol     --> kcat   --> Kafka --> CK Kafka Engine --> MergeTree
```

This creates a **split observability pipeline**:

| Data type | Path | Storage |
|-----------|------|---------|
| Logs (message, turn, permission) | Vector/Kcat -> Kafka -> CK | ClickHouse MergeTree |
| Metrics (counters, histograms) | OTel SDK -> Collector -> Prometheus | Prometheus TSDB |
| **Traces (spans)** | **OTel SDK -> Collector -> Tempo** | **Tempo** |

Three different storage backends, three retention policies, three query interfaces. Trace-to-logs correlation requires Tempo-to-ClickHouse linking (TraceQL or derived fields).

**This doc proposes an alternative**: route OTel spans through the same Kafka bus, store them in ClickHouse alongside log events, and eliminate the separate trace store.

```
cc-connect --OTLP--> OTel Collector --> Kafka ("otel.spans")
patrol     --OTLP--> OTel Collector --> Kafka ("otel.spans")
                                        |
                                        v
                                   CK Kafka Engine
                                        |
                                        v
                                   MergeTree (otel.span_log)
                                        |
                                        v
                                   Grafana (ClickHouse datasource)
```

---

## 2. Architecture

### 2.1 High-Level Diagram

```
┌──────────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  cc-connect          │     │  OTel Collector   │     │  ClickHouse      │
│  (Go, OTel SDK)      │────>│  (otel-collector  │────>│  (Kafka Engine)  │
│                      │     │   container)      │     │                  │
│   traces + metrics   │     │                   │     │  otel.span_log   │
│   via OTLP gRPC      │     │  receivers: otlp  │     │  (MergeTree)     │
│                      │     │  processors:      │     │                  │
├──────────────────────┤     │   - batch         │     ├──────────────────┤
│  patrol              │     │   - attributes    │     │  Grafana         │
│  (Ruby, OTel SDK)    │────>│   - kafkaexporter │────>│  (ClickHouse DS) │
│                      │     │                   │     │                  │
│   traces + metrics   │     │  exporters:       │     │  Span search,    │
│   via OTLP HTTP      │     │   - kafka (spans) │     │  trace view,     │
│                      │     │   - prometheus    │     │  trace-to-logs   │
└──────────────────────┘     └──────────────────┘     └──────────────────┘
                                          │
                                          │ (optional, for compatibility)
                                          v
                                     ┌──────────┐
                                     │  Tempo   │  (future: remove)
                                     └──────────┘

```

The OTel Collector receives spans via OTLP and **dual-writes**:
- Primary: Kafka topic `otel.spans` (for ClickHouse consumption)
- Secondary (optional): Tempo via OTLP (for backward compatibility during migration)

This means the Collector's Kafka exporter serializes each span (or span batch) as a Kafka message, and ClickHouse consumes it via Kafka Engine into a `otel.span_log` MergeTree table.

### 2.2 Why This, Not That

| Concern | Direct OTLP -> Tempo | OTel -> Kafka -> CK |
|---------|---------------------|---------------------|
| Storage backends | Tempo + Prometheus + CK | CK only (metrics via Prometheus, but Prometheus is already necessary) |
| Query interface | TraceQL (Tempo) + SQL (CK) | SQL only |
| Trace-to-logs join | Tempo-CK derived fields / trace ID lookup | Same table, same query |
| Retention management | Tempo retention + CK retention | Single CK TTL |
| Operational cost | Tempo (additional container, config, storage) | No additional backend |
| Replay capability | None (Tempo has no replay) | Kafka retention enables replay |
| Backpressure | Tempo slow -> spans dropped | Kafka buffers, CK consumes at its pace |
| Complexity | Two backends, two pipelines | One unified Kafka pipeline |

### 2.3 When This Makes Sense

This architecture is attractive when:

1. **You already have Kafka** for your event bus (we do -- see `kafka-message-bus.md`).
2. **You already have ClickHouse** for log storage (we do -- see `observability-design.md`).
3. **Trace volume is low** (< 100K spans/day). At higher volume, ClickHouse query performance for trace visualization becomes a concern (see section 8).
4. **Unified query is more valuable than specialized trace features.** If you rarely use TraceQL's advanced features (span links, nested graph, service graph), CK-based storage is simpler.
5. **You want replay.** Kafka retention means you can re-consume spans into a new table or reprocess them.

When it does NOT make sense:
- High span volume (ClickHouse is not optimized for tree-traversal queries like Tempo is).
- Heavy dependency on TraceQL or service graph metrics (Tempo does these natively).
- Need for probabilistic/tail-based sampling at the trace level (Tempo's built-in sampling vs. manual implementation in CK).

---

## 3. Kafka Topic: `otel.spans`

### 3.1 Configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Partitions | 3 | Match `cc.events`; partition by `trace_id` hash preserves per-trace ordering |
| Replication factor | 1 | Single broker |
| Retention | 3 days | Span data is less valuable for replay than log events; 3d is enough for debugging |
| Cleanup policy | `delete` | Simple time-based |
| Message key | `trace_id` (hex string) | Ensures all spans in a trace land in the same partition, preserving order within the trace |

### 3.2 Message Format

Each Kafka message is a single OTel span serialized as JSON (or Avro -- see section 3.3). The span follows the OTel span data model:

```json
{
  "trace_id": "0af7651916cd43dd8448eb211c80319c",
  "span_id": "b7ad6b7169203331",
  "parent_span_id": "0000000000000000",
  "name": "feishu.message.receive",
  "kind": 3,
  "start_time_unix_nano": "1680000000000000000",
  "end_time_unix_nano": "1680000005000000000",
  "attributes": [
    {"key": "feishu.msg_id", "value": {"string_value": "om_abc123"}},
    {"key": "feishu.chat_id", "value": {"string_value": "oc_xxx"}},
    {"key": "messaging.system", "value": {"string_value": "feishu"}}
  ],
  "events": [
    {
      "time_unix_nano": "1680000002000000000",
      "name": "feishu.raw_event",
      "attributes": [
        {"key": "event.length", "value": {"int_value": 1024}}
      ]
    }
  ],
  "status": {"code": 1, "message": ""},
  "resource": {
    "attributes": [
      {"key": "service.name", "value": {"string_value": "cc-connect"}},
      {"key": "service.version", "value": {"string_value": "1.0.0"}},
      {"key": "host.name", "value": {"string_value": "kyb-boss"}}
    ]
  },
  "scope": {
    "name": "cc-connect-tracer",
    "version": "1.0.0"
  }
}
```

**Size estimate**:
- Minimal span (~3 attributes, no events): ~400 bytes JSON
- Full span (~15 attributes, 2 events): ~1.2 KB JSON
- Typical span with context: ~600-800 bytes

### 3.3 Encoding: JSON vs Avro

| Factor | JSON | Avro |
|--------|------|------|
| Readability | Human-readable | Binary, not readable |
| Size | ~600-800 bytes/span | ~200-300 bytes/span |
| Schema evolution | Flexible (any JSON is valid) | Requires schema registry |
| ClickHouse Kafka Engine | Native `JSONEachRow` support | Requires `Avro` format + schema |
| Implementation effort | Zero (OTel Collector JSON exporter built-in) | Needs schema registry container + Avro serializer |

**Recommendation**: Use **JSON** for now. At our scale (~540 spans/day, ~400 KB/day), the space savings from Avro are irrelevant, and the operational simplicity of `JSONEachRow` in ClickHouse Kafka Engine is significant.

If span volume grows to > 1M spans/day, switch to Avro with Redpanda Schema Registry.

---

## 4. OTel Collector Configuration

### 4.1 Collector Pipeline

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
  attributes:
    actions:
      # Ensure trace_id is always present and formatted as hex
      - key: trace_id
        action: insert
        value: ""
    # Add deployment environment to all spans
    - key: deployment.environment
      action: insert
      value: "production"

exporters:
  kafka:
    # Primary: spans to Kafka
    protocol_version: 2.0.0
    brokers: [host.orb.internal:9092]
    topic: otel.spans
    encoding: json
    # Use trace_id as Kafka message key
    partition_trace_id: true
  
  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: otel_collector
  
  otlp/tempo:
    # Secondary: optional, for migration
    endpoint: tempo.monitoring:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch, attributes]
      exporters: [kafka]
      # Uncomment during migration to dual-write:
      # exporters: [kafka, otlp/tempo]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
```

### 4.2 Key Design Decisions

**`partition_trace_id: true`** -- Ensures all spans for the same trace go to the same Kafka partition. This preserves within-trace ordering, which ClickHouse Kafka Engine relies on if you need to reconstruct trace trees.

**No sampling processor** -- At ~540 spans/day, we sample everything. If volume grows, add a `probabilistic_sampler` processor before the kafka exporter.

**Dual-write during migration** -- The `otlp/tempo` exporter is present but disabled in the traces pipeline. Enable it during migration to run Tempo and CK in parallel, then remove Tempo once verified.

---

## 5. ClickHouse Schema

### 5.1 Kafka Engine Table (Raw)

```sql
CREATE TABLE otel.kafka_queue (
    trace_id        String,
    span_id         String,
    parent_span_id  String,
    name            String,
    kind            UInt8,
    start_time      DateTime64(9),
    end_time        DateTime64(9),
    duration_ns     Int64,
    status_code     UInt8,
    status_message  String,
    service_name    LowCardinality(String),
    service_version String,
    host_name       String,
    attributes_json String,
    events_json     String,
    resource_json   String,
    scope_name      String,
    scope_version   String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'otel.spans',
    kafka_group_name = 'ck-consumer-otel',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3,
    kafka_skip_broken_messages = 100;
```

**Notes**:
- `duration_ns` is computed as `end_time_unix_nano - start_time_unix_nano` by the OTel Collector (or derived at insert time via MATERIALIZED VIEW).
- `attributes_json` stores the raw attributes array as a JSON string for ad-hoc querying. Frequently-queried attributes are extracted to dedicated columns in the target table.
- `events_json` stores span events (annotations) as JSON.
- `kafka_skip_broken_messages = 100` allows up to 100 malformed messages before the consumer stops.

### 5.2 Target MergeTree Table

```sql
CREATE TABLE otel.span_log (
    event_time      DateTime64(9),
    trace_id        String,
    span_id         String,
    parent_span_id  String,
    name            LowCardinality(String),
    kind            UInt8,
    start_time      DateTime64(9),
    end_time        DateTime64(9),
    duration_ns     Int64,
    status_code     UInt8,
    status_message  String,
    service_name    LowCardinality(String),
    service_version String,
    host_name       String,
    
    -- Frequently-queried span attributes extracted as columns
    feishu_msg_id       String,
    feishu_chat_id      String,
    feishu_sender_id    String,
    cc_session          String,
    cc_agent_session    String,
    claude_request_model String,
    claude_input_tokens  UInt32,
    claude_output_tokens UInt32,
    claude_stop_reason   LowCardinality(String),
    http_response_status_code UInt16,
    cc_tool_name        LowCardinality(String),
    cc_tool_duration_ms UInt32,
    cc_permission_request_id String,
    cc_permission_decision LowCardinality(String),
    patrol_round_id     String,
    patrol_round_status LowCardinality(String),
    
    -- Raw JSON blobs for forward compatibility
    attributes_json     String,
    events_json         String,
    resource_json       String,
    scope_name          String,
    scope_version       String
) ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (event_time, trace_id, start_time)
TTL event_time + INTERVAL 30 DAY;
```

**Why so many extracted columns?**
- Avoid parsing JSON at query time (slow in ClickHouse).
- Enable efficient filtering: `WHERE service_name = 'cc-connect' AND claude_input_tokens > 500`.
- The extracted columns are populated by a MATERIALIZED VIEW (see below).

### 5.3 Materialized View

```sql
CREATE MATERIALIZED VIEW otel.kafka_to_span_log TO otel.span_log AS
SELECT
    -- Timestamps
    toDateTime64(end_time / 1000000000, 9) AS event_time,
    
    -- IDs
    trace_id,
    span_id,
    parent_span_id,
    
    -- Span metadata
    name,
    kind,
    toDateTime64(start_time / 1000000000, 9) AS start_time,
    toDateTime64(end_time / 1000000000, 9) AS end_time,
    toInt64(end_time - start_time) AS duration_ns,
    status_code,
    status_message,
    
    -- Resource attributes
    service_name,
    service_version,
    host_name,
    
    -- Extracted attributes (JSON parsing)
    extract_attribute(attributes_json, 'feishu.msg_id') AS feishu_msg_id,
    extract_attribute(attributes_json, 'feishu.chat_id') AS feishu_chat_id,
    extract_attribute(attributes_json, 'feishu.sender_id') AS feishu_sender_id,
    extract_attribute(attributes_json, 'cc.session') AS cc_session,
    extract_attribute(attributes_json, 'cc.agent_session') AS cc_agent_session,
    extract_attribute(attributes_json, 'claude.request.model') AS claude_request_model,
    extract_attribute(attributes_json, 'claude.response.input_tokens') AS claude_input_tokens,
    extract_attribute(attributes_json, 'claude.response.output_tokens') AS claude_output_tokens,
    extract_attribute(attributes_json, 'claude.response.stop_reason') AS claude_stop_reason,
    extract_attribute(attributes_json, 'http.response.status_code') AS http_response_status_code,
    extract_attribute(attributes_json, 'cc.tool.name') AS cc_tool_name,
    extract_attribute(attributes_json, 'cc.tool.duration_ms') AS cc_tool_duration_ms,
    extract_attribute(attributes_json, 'cc.permission.request_id') AS cc_permission_request_id,
    extract_attribute(attributes_json, 'cc.permission.decision') AS cc_permission_decision,
    extract_attribute(attributes_json, 'patrol.round.id') AS patrol_round_id,
    extract_attribute(attributes_json, 'patrol.round.status') AS patrol_round_status,
    
    -- Raw JSON
    attributes_json,
    events_json,
    resource_json,
    scope_name,
    scope_version
FROM otel.kafka_queue;
```

### 5.4 Helper Function

ClickHouse does not have a native `extract_attribute` function for the OTel attributes array format. You need a helper function or use JSON path extraction:

```sql
-- Option A: Assume attributes_json is a JSON object (if serialized as map by Collector)
-- Simpler, works when Collector serializes attributes as key-value map
-- e.g., "attributes_json": '{"feishu.msg_id": "om_abc123", ...}'
SELECT JSONExtractString(attributes_json, 'feishu.msg_id') AS feishu_msg_id

-- Option B: OTel attributes array format
-- e.g., "attributes_json": '[{"key": "feishu.msg_id", "value": {"string_value": "om_abc123"}}]'
-- Requires arrayFirst + JSON path
SELECT arrayFirst(
    x -> JSONExtractString(x, 'key') = 'feishu.msg_id',
    JSONExtractArrayRaw(attributes_json)
) AS feishu_msg_id_raw
```

**Recommendation**: Configure the OTel Collector's Kafka exporter to serialize attributes as a **flat JSON map** (not the OTel protobuf array format). Most OTel Collector Kafka exporters support this via a `marshal` or `format` option. This makes JSON extraction trivial:

```sql
SELECT JSONExtractString(attributes_json, 'feishu.msg_id') AS feishu_msg_id
```

---

## 6. Trace Tree Reconstruction in ClickHouse

The main challenge with ClickHouse-based span storage: **reconstructing the trace tree** (parent-child relationships) for waterfall visualization in Grafana.

### 6.1 Query for Full Trace

```sql
SELECT
    span_id,
    parent_span_id,
    name,
    kind,
    start_time,
    end_time,
    duration_ns,
    status_code,
    service_name,
    attributes_json,
    events_json
FROM otel.span_log
WHERE trace_id = '0af7651916cd43dd8448eb211c80319c'
ORDER BY start_time ASC;
```

This returns all spans for a trace, sorted by start time. The caller (Grafana or custom frontend) must reconstruct the tree by matching `parent_span_id` to `span_id`.

### 6.2 Grafana Visualization

Grafana's ClickHouse datasource plugin supports a **trace view** (waterfall chart) when the query returns the required columns:

| Column | Required | Description |
|--------|----------|-------------|
| `trace_id` | Yes | Trace identifier |
| `span_id` | Yes | Span identifier |
| `parent_span_id` | Yes | Parent span ID |
| `service_name` | Yes | Service/resource name |
| `operation_name` | Yes | Span name (alias: `name`) |
| `duration_ns` | Yes | Span duration in nanoseconds |
| `start_time` | Yes | Span start time |

The query format for Grafana ClickHouse trace view:

```sql
SELECT
    trace_id,
    span_id,
    parent_span_id,
    service_name,
    name AS operation_name,
    duration_ns,
    start_time,
    status_code,
    attributes_json
FROM otel.span_log
WHERE trace_id = '$trace_id'
ORDER BY start_time ASC;
```

### 6.3 Limitations vs. Tempo

| Feature | Tempo | ClickHouse |
|---------|-------|------------|
| TraceQL query language | Native | Not supported (use SQL) |
| Service graph | Built-in | Manual (aggregate edges from parent/child spans) |
| Span links | Native | Manual JOIN on span_id |
| Trace search by attribute | `{service.name="cc-connect"}` | SQL `WHERE service_name = 'cc-connect'` |
| Search performance | Optimized for trace ID lookup | Requires secondary index on trace_id |
| Waterfall UI | Built-in | Grafana plugin (may be less polished) |

If you rely heavily on TraceQL or need sub-second trace search across millions of spans, Tempo is the better choice. At our scale (< 1000 spans/day), ClickHouse query performance is more than adequate.

---

## 7. Migration Path

### Phase 0: No traces (current)

```
cc-connect -> slog logs -> Vector -> CK
patrol     -> heartbeat  -> kcat  -> CK
```

No tracing at all. Only logs and heartbeats.

### Phase 1: OTel SDK + direct OTLP to Tempo (as designed in otel-cc-connect.md)

```
cc-connect --OTLP--> OTel Collector --> Tempo
patrol     --OTLP--> OTel Collector --> Tempo
```

Adds distributed tracing with minimal complexity. Tempo handles trace storage and query.

### Phase 2: Dual-write (Kafka + Tempo)

```
cc-connect --OTLP--> OTel Collector --> Kafka --> CK (otel.span_log)
                    (dual-write)  --> Tempo (migration monitor)
patrol     --OTLP--> OTel Collector --> Kafka --> CK
                    (dual-write)  --> Tempo
```

Kafka exporter added to OTel Collector. Collector dual-writes to both Kafka (primary) and Tempo (migration monitor). Run both for 3-7 days to verify:

- Row counts match between Tempo and CK (number of spans ingested).
- Grafana trace view works with ClickHouse datasource.
- Trace-to-logs correlation works (same query, same table).

### Phase 3: Kafka only (Tempo removed)

```
cc-connect --OTLP--> OTel Collector --> Kafka --> CK (otel.span_log)
patrol     --OTLP--> OTel Collector --> Kafka --> CK
```

Tempo container removed. All trace storage and query via ClickHouse. Metrics still go to Prometheus (OTel Collector Prometheus exporter).

### Phase 4 (optional): Tempo returns

If ClickHouse trace query performance is insufficient after volume growth (e.g., > 1M spans/day), add Tempo back as a dedicated trace store. Kafka stays as the ingestion bus -- add a new consumer that reads from `otel.spans` and writes to Tempo via OTLP, rather than the Collector dual-writing.

```
otel.spans (Kafka) --> CK consumer (otel.span_log, for SQL queries)
                  --> Tempo consumer (for TraceQL + service graph)
```

This is the best of both worlds: unified ingestion via Kafka, but specialized storage per query pattern.

---

## 8. Pros/Cons Summary

### Pros of OTel -> Kafka -> CK

| Pro | Detail |
|-----|--------|
| **Unified pipeline** | All observability data (logs, spans, events) goes through the same Kafka bus. One set of infrastructure to manage, monitor, and debug. |
| **Single storage backend** | CK replaces Tempo. One retention policy, one backup strategy, one query interface. |
| **Trace-to-logs without joining** | Logs and spans in the same database, can be joined in a single SQL query. No Tempo-CK bridge or derived fields needed. |
| **Replay capability** | Kafka retains spans for 3d. If CK schema changes or data is corrupted, replay from Kafka. Tempo has no replay. |
| **Decoupled ingestion** | CK can be down for minutes/hours without losing spans. Kafka buffers. In direct OTel -> Tempo, if Tempo is down, spans are dropped (OTel SDK's default is to drop on export failure). |
| **Simplified operational stack** | Remove Tempo container, config, and maintenance. Fewer things to break. |
| **Already have Kafka + CK** | The infrastructure is already in place (see `kafka-message-bus.md`). Adding span events is just a new topic + CK table. |

### Cons of OTel -> Kafka -> CK

| Con | Detail | Mitigation |
|-----|--------|------------|
| **CK is not a trace DB** | ClickHouse is optimized for analytical queries on flat tables, not tree traversal (parent-child span resolution). Trace waterfall queries require reconstructing the tree in the application layer. | At our scale (< 1000 spans/day), the performance difference is negligible. CK with secondary index on `trace_id` handles this fine. |
| **No TraceQL** | Grafana's Tempo datasource supports TraceQL for advanced trace search ("find traces where `http.status_code >= 500` and duration > 1s"). CK SQL is more verbose. | SQL can express the same queries, just with more typing. Grafana's ClickHouse plugin supports trace waterfall view with the right query format. |
| **No service graph** | Tempo generates service graph metrics (dependency map between services). Manual in CK. | With only 2-3 services (cc-connect, patrol), service graph is not valuable. If we add 10+ services, reconsider. |
| **Custom extractor logic** | Span attributes (in OTel array format) must be extracted into columns via MATERIALIZED VIEW. This requires maintaining attribute mappings. | The OTel Collector can serialize attributes as a flat JSON map, avoiding the array format. Then `JSONExtractString` works directly. |
| **Grafana maturity** | Grafana's ClickHouse trace waterfall view is less mature than the Tempo-native waterfall. Might have visual glitches or missing features. | Test in Phase 2 dual-write period. If unacceptable, keep Tempo. |
| **Latency in visibility** | Kafka adds ~1s (batch interval) + CK ingestion latency. Direct OTLP to Tempo is near real-time. | 1-2s latency is irrelevant for post-mortem analysis. For real-time alerting, use metrics (Prometheus), not traces. |

### Decision Matrix

| Criteria | Direct OTel -> Tempo | OTel -> Kafka -> CK |
|----------|---------------------|---------------------|
| Implementation effort | Low (standard OTel setup) | Medium (Kafka topic + CK table + extractor) |
| Operational complexity | Medium (Tempo + CK + Prometheus = 3 backends) | Low (CK + Prometheus = 2 backends, reuse Kafka) |
| Query capability | Excellent (TraceQL, service graph) | Good (SQL, Grafana waterfall plugin) |
| Replay capability | None | Yes (Kafka retention) |
| Resiliency | Low (Tempo down = lost spans) | High (Kafka buffers) |
| Trace-to-logs correlation | Medium (Tempo-CK bridge) | Native (same DB) |
| Scale ceiling | Very high (Tempo is built for traces) | Medium (CK trace queries degrade at > 1M spans/day) |
| Cost (infra) | Tempo container (~256 MB RAM) | No additional container (reuse CK) |

**For our current scale (~540 spans/day)**: OTel -> Kafka -> CK is the better choice. The simplicity of a single pipeline and single storage backend outweighs the advanced trace features we won't use at this volume.

---

## 9. Operational Notes

### 9.1 Monitoring the Pipeline

| What | How | Alert if |
|------|-----|----------|
| Spans reaching CK | `SELECT count() FROM otel.span_log WHERE event_time > now() - INTERVAL 1 HOUR` | Count drops to 0 for > 1 hour |
| Kafka consumer lag | `rpk group describe ck-consumer-otel` | Lag > 1000 (at current volume, should be 0-10) |
| OTel Collector health | Collector metrics endpoint (`/metrics`) pool size, exporter errors | Export errors > 0 for > 5 min |
| Broken messages | `kafka_skip_broken_messages` count | Check ClickHouse system.errors for Kafka-related errors |

### 9.2 Kafka Topic Sizing

At 540 spans/day x 800 bytes = ~430 KB/day for CC-connect, plus patrol (~100 spans/day x 500 bytes = 50 KB/day). Total: **~500 KB/day**.

3-day retention: ~1.5 MB. Even with 10x growth: ~15 MB. This is negligible for any Kafka setup.

### 9.3 Retention

| Layer | Retention | Why |
|-------|-----------|-----|
| Kafka `otel.spans` | 3 days | Window for replay after CK failure |
| CK `otel.span_log` | 30 days | Debugging window for recent issues |
| CK aggregate tables (future) | 90 days | Derived metrics (P50/P90 duration per service per day) |

30-day CK retention at 500 KB/day = ~15 MB. Even with 10x growth: ~150 MB. CK will not notice this.

### 9.4 Grafana Dashboard

Add a "Trace Search" dashboard with:

1. **Trace search by trace_id** -- input variable, query `otel.span_log` for waterfall view
2. **Trace search by attribute** -- `WHERE feishu_msg_id = '$msg_id'` to find trace from a Feishu message
3. **Recent traces** -- `SELECT trace_id, service_name, name, start_time, duration_ns FROM otel.span_log WHERE parent_span_id = '' ORDER BY start_time DESC LIMIT 50`
4. **Slow traces** -- traces where max(duration_ns) > 30s threshold
5. **Span count / service** -- `SELECT service_name, count() as spans, countDistinct(trace_id) as traces FROM otel.span_log WHERE event_time > now() - INTERVAL 1 DAY GROUP BY service_name`

---

## 10. Future Considerations

### 10.1 Span Events as Separate Messages

Currently, span events (annotations like `feishu.raw_event`, `claude.request.body`) are embedded in the span's `events` field as JSON. If we want to search/filter on span events independently, we can:

1. Publish span events as **separate Kafka messages** to a `otel.span_events` topic.
2. Store them in a separate `otel.span_event_log` table with columns: `trace_id`, `span_id`, `event_name`, `event_time`, `event_attributes_json`.
3. JOIN with `otel.span_log` on `(trace_id, span_id)`.

Pro: Independent querying of span events without JSON parsing.
Con: Doubles the number of Kafka messages and CK rows.

**Recommendation**: Keep events embedded in the span's `events_json` column. Extract to a separate table only if we need to query events frequently (e.g., "find all traces where permission was requested for tool X").

### 10.2 Metrics via Kafka

The same pattern can extend to OTel metrics: export metrics to a `otel.metrics` Kafka topic, consume into `otel.metric_log` in CK, and query with Grafana.

However, Prometheus is already serving this role well. CK is not a real-time metrics store (no PromQL, no alert evaluation). Keep metrics on Prometheus.

### 10.3 Sampling at Scale

If span volume grows to > 100K/day:

1. Add **probabilistic sampling** in the OTel Collector: `probabilistic_sampler` processor with `sampling_percentage = 10`.
2. Use **head-based sampling** (simpler) vs **tail-based sampling** (more accurate, but needs a load-balancing exporter).
3. Consider **priority sampling**: errors always sampled, slow spans always sampled, fast spans sampled at 1%.

### 10.4 Trace ID Index

At scale, `WHERE trace_id = '0af765...'` without an index will do a full table scan. Add a **skip index** on `trace_id`:

```sql
ALTER TABLE otel.span_log ADD INDEX trace_id_idx (trace_id) TYPE bloom_filter GRANULARITY 1;
```

This creates a bloom filter per granule (8192 rows), allowing ClickHouse to skip granules that do not contain the target trace_id. At our current volume, this is unnecessary but good practice.

---

## 11. Related Documents

| Document | Relevance |
|----------|-----------|
| `docs/infra/reviews/kafka-message-bus.md` | Kafka infrastructure, topic design, producer integration |
| `docs/infra/reviews/otel-cc-connect.md` | OTel trace model for cc-connect (span definitions, attributes) |
| `docs/infra/reviews/otel-patrol.md` | OTel trace model for patrol (round lifecycle spans) |
| `docs/infra/observability-design.md` | Overall observability strategy, CK schema for logs |
| `docs/infra/reviews/otel-cc-connect.md` (sampling section) | Sampling strategy for low-volume traces |
| `docs/infra/reviews/otel-mcp.md` | OTel for MCP (related trace model, not in scope here) |
