---
decision: 不应该做
---

# OTel + Kafka + Vector: Full Stack Observability Pipeline

**Date**: 2026-05-23
**Status**: Design proposal
**Scope**: End-to-end pipeline for traces, metrics, and logs from OTel-instrumented applications through Kafka to Vector and into ClickHouse. Redundant paths, failure modes, operational playbook.

---

## 1. Motivation

We have two independent observability designs that solve adjacent problems:

1. **OTel for cc-connect** (see `otel-cc-connect.md`): Distributed tracing for message turns, spans for each processing stage, exported via OTLP to Tempo + Prometheus.
2. **Kafka Message Bus** (see `kafka-message-bus.md`): Durable event bus decoupling producers from ClickHouse, with replay capability and unified schema.

These two designs share a gap: **OTel traces never reach Kafka**, and the **Kafka bus has no native OTLP support**. If we deploy both independently, we end up with:

- Traces go OTel Collector -> Tempo (no replay, no CK persistence)
- Metrics go OTel Collector -> Prometheus (no replay, no CK persistence)
- Logs go Vector -> CK (with Kafka in the future, but no OTel integration)
- Events go producers -> Kafka -> CK (via CK Kafka Engine, no Vector transform)

The result is **three parallel pipelines** with no unified backpressure, replay, or schema governance.

### Solution: OTel Collector -> Kafka -> Vector -> ClickHouse

```
All sources ──OTLP──► OTel Collector ──► Kafka ──► Vector ──► ClickHouse
                                              │
                                         (durable buffer,
                                          replay-capable,
                                          multi-consumer)
```

Every observability data type (traces, metrics, logs) flows through the same pipeline:

1. **OTel Collector** receives OTLP from all instrumented apps, fans out to Kafka + real-time backends
2. **Kafka** provides durable buffering, replay, backpressure isolation
3. **Vector** consumes from Kafka, transforms data, sinks to ClickHouse (and future backends)

This replaces the current ad-hoc architecture where traces, metrics, and logs each have independent delivery paths and failure modes.

---

## 2. Architecture

### 2.1 Topology

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Instrumented Apps                            │
│                                                                     │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐            │
│  │  cc-connect   │   │   patrol      │   │ future apps  │            │
│  │  (Go OTel)    │   │  (Ruby OTel)  │   │  (any lang)  │            │
│  └──────┬───────┘   └──────┬───────┘   └──────┬───────┘            │
│         │ OTLP gRPC        │ OTLP HTTP        │ OTLP gRPC/HTTP      │
└─────────┼──────────────────┼──────────────────┼─────────────────────┘
          │                  │                  │
          ▼                  ▼                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                      OTel Collector                                  │
│                                                                      │
│  receivers: otlp (gRPC :4317, HTTP :4318)                           │
│                                                                      │
│  processors:                                                         │
│    - batch (timeout: 1s, max_size: 1024)                            │
│    - memory_limiter (limit: 512 MiB)                                │
│    - attributes (add deployment environment, host info)             │
│    - filter (drop debug spans when sampling)                        │
│                                                                      │
│  exporters:                                                          │
│    ├── kafka/traces  ──────► Kafka topic: otlp.traces               │
│    ├── kafka/metrics ──────► Kafka topic: otlp.metrics              │
│    ├── kafka/logs    ──────► Kafka topic: otlp.logs                 │
│    ├── otlp/tempo    ──────► Tempo (real-time trace search)         │
│    └── prometheus    ──────► Prometheus (real-time metrics)         │
│                                                                      │
│  redundancy: Kafka export is primary; Tempo/Prometheus are optional  │
│  real-time side-channels that can be disabled without data loss.     │
└────────────────────────┬─────────────────────────────────────────────┘
                         │ Kafka (OTLP Protobuf serialized messages)
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    Kafka / Redpanda                                   │
│                                                                      │
│  topics:                                                             │
│    otlp.traces      ── partitions: 3, retention: 7d                 │
│    otlp.metrics     ── partitions: 2, retention: 14d                │
│    otlp.logs        ── partitions: 2, retention: 7d                 │
│                                                                      │
│  key strategy: trace_id hash → preserves per-trace ordering         │
│  key strategy: metric name hash → preserves per-metric ordering     │
│                                                                      │
│  Provides: durable buffer, replay, backpressure isolation            │
└────────────────────────┬─────────────────────────────────────────────┘
                         │ Kafka consumer (consumer group: vector-ck)
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Vector                                                              │
│                                                                      │
│  sources:                                                            │
│    kafka_otlp_traces  ── topic: otlp.traces,                         │
│    kafka_otlp_metrics ── topic: otlp.metrics,                        │
│    kafka_otlp_logs    ── topic: otlp.logs                            │
│                                                                      │
│  transforms:                                                         │
│    parse_otlp_proto ── decode OTLP Protobuf → structured fields     │
│    enrich           ── add deployment metadata, normalize timestamps │
│    route_by_type    ── traces → trace table, metrics → metric table  │
│                                                                      │
│  sinks:                                                              │
│    clickhouse_traces  ──► ClickHouse: otel.traces                    │
│    clickhouse_metrics ──► ClickHouse: otel.metrics                   │
│    clickhouse_logs    ──► ClickHouse: otel.logs                      │
│                                                                      │
│  redundancy: Vector is the primary CK consumer, but CK Kafka Engine  │
│  can be used as fallback if Vector is down (dual consumption).       │
└────────────────────────┬─────────────────────────────────────────────┘
                         │ ClickHouse Native Protocol
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│  ClickHouse                                                          │
│                                                                      │
│  databases:                                                          │
│    otel ── all OTel-derived tables                                  │
│    cc   ── existing cc-connect tables (legacy)                       │
│                                                                      │
│  tables (otel.*):                                                    │
│    traces     ── span records with attributes                        │
│    metrics    ── metric time-series with labels                      │
│    logs       ── log records with resource attributes                │
│                                                                      │
│  TTL: 90 days for all tables                                        │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow Detail

#### Trace path (end-to-end)

```
cc-connect handles message
    │ tracer.Start(ctx, "feishu.message.receive")
    ▼
Span ends → OTel SDK batch export
    │ OTLP gRPC → otel-collector:4317
    ▼
OTel Collector otlp receiver
    │ batch processor → kafka exporter
    ▼
Kafka topic: otlp.traces (partition by trace_id hash)
    │ retained for 7 days
    ▼
Vector kafka source (consumer group vector-ck)
    │ remap transform: parse OTLP Protobuf → structured record
    │ route to clickhouse_traces sink
    ▼
ClickHouse: otel.traces (MergeTree, ORDER BY (TraceId, SpanId))
```

#### Trace path (real-time side-channel, redundant)

```
OTel Collector
    │ otlp/tempo exporter (parallel to kafka export)
    ▼
Tempo (real-time trace search in Grafana)
    │ data not persisted beyond Tempo retention (24h default)
    └── not affected by Kafka/CK downtime
```

#### Metric path

```
cc-connect records counter: cc.messages.received
    │ OTel SDK → OTLP export
    ▼
OTel Collector
    │ kafka exporter (primary) + prometheus exporter (side-channel)
    ▼
Kafka: otlp.metrics → Vector → ClickHouse: otel.metrics
Prometheus: scraped by Prometheus server for real-time dashboards
```

#### Log path (non-OTel sources, future)

```
cc-connect (slog stdout)
    │ Vector docker_logs source (existing pipeline, for migration)
    ▼
Vector
    │ kafka sink → topic: otlp.logs (bridge legacy logs into unified bus)
    ▼
Kafka: otlp.logs → Vector (second pass) → ClickHouse: otel.logs
```

This last path is transitional. Once cc-connect has native OTel logging, `slog` output goes through the OTel SDK and enters the pipeline at the OTel Collector, bypassing the legacy Vector docker_logs source entirely.

---

## 3. Component Details

### 3.1 OTel Collector

#### Deployment

```bash
docker run -d \
  --name kyb-infra-otel-collector \
  --restart unless-stopped \
  --network kyb-infra \
  -p 4317:4317 \
  -p 4318:4318 \
  -v otel-collector-config:/etc/otel-collector \
  otel/opentelemetry-collector-contrib:latest
```

Uses the `-contrib` image for the Kafka exporter. The non-contrib image does not include the Kafka exporter.

#### Config

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
      - key: deployment.environment
        value: "production"
        action: upsert
      - key: service.namespace
        value: "kyb-infra"
        action: upsert

exporters:
  # Primary: Kafka (durable, replay-capable)
  kafka/traces:
    brokers: ["host.orb.internal:9092"]
    topic: "otlp.traces"
    encoding: "otlp_proto"
    protocol_version: "0.0.0"  # auto-negotiate
    metadata:
      retry_max: 3
      retry_backoff: 100ms

  kafka/metrics:
    brokers: ["host.orb.internal:9092"]
    topic: "otlp.metrics"
    encoding: "otlp_proto"
    protocol_version: "0.0.0"

  kafka/logs:
    brokers: ["host.orb.internal:9092"]
    topic: "otlp.logs"
    encoding: "otlp_proto"
    protocol_version: "0.0.0"

  # Real-time side-channels (optional, can be removed without data loss)
  otlp/tempo:
    endpoint: tempo.monitoring:4317
    tls:
      insecure: true

  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: kyb_otel

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch, attributes]
      exporters: [kafka/traces, otlp/tempo]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch, attributes]
      exporters: [kafka/metrics, prometheus]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch, attributes]
      exporters: [kafka/logs]
```

#### Redundancy design in the OTel Collector

The collector is the **single ingestion point** for all OTel data. Its internal fan-out guarantees:

- **If Kafka is down**: The `kafka/*` exporters will retry with backpressure. The `batch` processor buffers in memory (up to 512 MiB). If Kafka stays down beyond the memory buffer, the collector applies backpressure to the producers (cc-connect buffering in its OTel SDK). The `otlp/tempo` and `prometheus` exporters remain unaffected.
- **If Tempo/Prometheus are down**: No impact on the primary pipeline. The collector logs the export error and continues. Data still flows through Kafka -> Vector -> CK.
- **If the collector itself is down**: Producers buffer traces in-memory (OTel SDK default: ~2048 spans). Once the collector comes back, buffered spans drain. Span loss only occurs if the producer process restarts while the collector is down.

### 3.2 Kafka Topics

| Topic | Partitions | Retention | Cleanup | Key | Message Format |
|-------|-----------|-----------|---------|-----|---------------|
| `otlp.traces` | 3 | 7 days | `delete` | `trace_id` (hash) | OTLP Protobuf |
| `otlp.metrics` | 2 | 14 days | `delete` | metric name (hash) | OTLP Protobuf |
| `otlp.logs` | 2 | 7 days | `delete` | none (round-robin) | OTLP Protobuf |
| `cc.events` | 3 | 7 days | `delete` | `msg_id` (hash) | JSON (legacy) |
| `patrol.events` | 1 | 7 days | `delete` | none | JSON (legacy) |

The first three topics (`otlp.*`) are new. The last two (`cc.events`, `patrol.events`) are from the Kafka Message Bus design and coexist during migration.

**Why OTLP Protobuf in Kafka instead of JSON?**

- OTLP Protobuf is the **canonical format** for OTel data. Parsing OTLP Protobuf -> JSON -> re-encoding loses type information (e.g., int64 -> string).
- Protobuf is more compact (~60% smaller than equivalent JSON).
- Vector's `kafka` source can decode OTLP Protobuf natively with the `otlp` decoding option.

**Why separate topics instead of one?**

- Different retention requirements (metrics keep 14d, traces/logs keep 7d).
- Different partitioning strategies (traces keyed by `trace_id`, metrics by metric name).
- Independent consumer scaling (traces can have 3 consumers, metrics 2).

#### Topic creation

```bash
rpk topic create otlp.traces  --partitions 3
rpk topic create otlp.metrics --partitions 2
rpk topic create otlp.logs    --partitions 2
```

#### Retention tuning rationale

- **7 days for traces**: Long enough for post-mortem analysis of issues discovered over a weekend. Most trace investigations happen within 48 hours.
- **14 days for metrics**: Metrics are smaller and used for trend analysis (weekly patterns, capacity planning).
- If CK is down for >7 days, traces in Kafka are lost. This is acceptable because CK is the system of record (90d TTL). If CK uptime is a concern, increase trace retention to 14d (cost: ~10 MB extra, negligible).

### 3.3 Vector

#### Deployment

```bash
docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  --network kyb-infra \
  -v vector-config:/etc/vector \
  timberio/vector:latest
```

#### Config

```toml
# ─── Sources (Kafka consumers) ────────────────────────────────────────────

[sources.kafka_traces]
type = "kafka"
inputs = []
bootstrap_servers = "host.orb.internal:9092"
group_id = "vector-ck-traces"
topics = ["otlp.traces"]
decoding.codec = "bytes"  # OTLP Protobuf raw bytes
auto_offset_reset = "earliest"

[sources.kafka_metrics]
type = "kafka"
inputs = []
bootstrap_servers = "host.orb.internal:9092"
group_id = "vector-ck-metrics"
topics = ["otlp.metrics"]
decoding.codec = "bytes"
auto_offset_reset = "earliest"

[sources.kafka_logs]
type = "kafka"
inputs = []
bootstrap_servers = "host.orb.internal:9092"
group_id = "vector-ck-logs"
topics = ["otlp.logs"]
decoding.codec = "bytes"
auto_offset_reset = "earliest"

# ─── Transforms ───────────────────────────────────────────────────────────

# Parse OTLP Protobuf into structured events.
# Vector does not natively decode OTLP Protobuf as of v0.42.
# Workaround: use Lua/Wasmer transform to call protobuf decoder,
# or route raw protobuf bytes to CK for server-side decoding.
#
# For the initial implementation, we take a simpler approach:
# store raw OTLP Protobuf in CK and decode at query time using
# ClickHouse's capability to handle Protobuf input format.
#
# See Section 3.4 for the CK schema design.

[transforms.add_metadata]
type = "remap"
inputs = ["kafka_traces", "kafka_metrics", "kafka_logs"]
source = '''
  .ingested_at = now()
  .pipeline_version = "otel-kafka-vector-v1"
  ._topic = string!(."topic") ?? "unknown"
  ._partition = ."partition" ?? 0
  ._offset = ."offset" ?? 0
'''

# ─── Sinks ────────────────────────────────────────────────────────────────

[sinks.clickhouse_traces]
type = "clickhouse"
inputs = ["add_metadata"]
endpoint = "http://host.orb.internal:8123"
database = "otel"
table = "traces_raw"
auth.strategy = "none"
encoding.json = true
batch.timeout_secs = 1
batch.max_events = 1000
request.retry_attempts = 3

[sinks.clickhouse_metrics]
type = "clickhouse"
inputs = ["add_metadata"]
endpoint = "http://host.orb.internal:8123"
database = "otel"
table = "metrics_raw"
auth.strategy = "none"
encoding.json = true
batch.timeout_secs = 1
batch.max_events = 1000
request.retry_attempts = 3

[sinks.clickhouse_logs]
type = "clickhouse"
inputs = ["add_metadata"]
endpoint = "http://host.orb.internal:8123"
database = "otel"
table = "logs_raw"
auth.strategy = "none"
encoding.json = true
batch.timeout_secs = 1
batch.max_events = 1000
request.retry_attempts = 3
```

**Note on OTLP Protobuf decoding**: Vector's `kafka` source does not have a built-in `otlp_proto` decoder. The above config stores raw OTLP bytes in ClickHouse. In a future iteration, Vector can use `wasm` or `lua` transform with a protobuf library to decode spans into structured fields before CK ingestion. For now, ClickHouse handles Protobuf decoding at query time (see Section 5).

#### Alternative: Vector with VRL-based OTLP decoding

In Vector >= 0.38, the `remap` transform supports VRL functions that can decode protobuf. If available:

```toml
[transforms.decode_otlp_traces]
type = "remap"
inputs = ["kafka_traces"]
source = '''
  # Decode OTLP TracesData protobuf
  # This is pseudocode: actual VRL syntax depends on Vector version
  . = parse_protobuf!(., "opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest")
  .resource_spans = .resource_spans ?? []
'''
```

If protobuf decoding in Vector is not available, see Section 5 for the ClickHouse-native approach.

### 3.4 ClickHouse Tables

#### Database

```sql
CREATE DATABASE IF NOT EXISTS otel;
```

#### Traces: raw storage

```sql
CREATE TABLE otel.traces_raw (
    timestamp   DateTime64(9),
    trace_id    String,
    span_id     String,
    parent_span_id String,
    trace_state String,
    span_name   String,
    span_kind   Int32,
    service_name String,
    resource_attributes Map(String, String),
    scope_name  String,
    scope_version String,
    span_attributes Map(String, String),
    status_code Int32,
    status_message String,
    events      Array(Tuple(
        time_delta  DateTime64(9),
        name        String,
        attributes  Map(String, String)
    )),
    links       Array(Tuple(
        trace_id    String,
        span_id     String,
        trace_state String,
        attributes  Map(String, String)
    )),
    duration_ns Int64,
    
    -- Vector metadata
    ingested_at DateTime64(3),
    _topic      String,
    _partition  Int32,
    _offset     Int64,
    
    -- Raw OTLP protobuf for reprocessing
    raw_body    String
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (trace_id, timestamp)
TTL timestamp + INTERVAL 90 DAY
```

#### Metrics: raw storage

```sql
CREATE TABLE otel.metrics_raw (
    timestamp       DateTime64(9),
    resource_attributes Map(String, String),
    scope_name      String,
    scope_version   String,
    metric_name     String,
    metric_description String,
    metric_unit     String,
    metric_type     Int32,  -- 0=gauge, 1=sum, 2=histogram, etc.
    
    -- Data points (flattened from OTLP's flexible structure)
    -- Gauge/Sum: single value
    value_double    Float64,
    value_int       Int64,
    -- Histogram
    count           Int64,
    sum             Float64,
    min             Float64,
    max             Float64,
    bucket_bounds   Array(Float64),
    bucket_counts   Array(Int64),
    
    attributes      Map(String, String),
    exemplars       Array(String),  -- JSON-encoded exemplars
    
    ingested_at     DateTime64(3),
    _topic          String,
    _partition      Int32,
    _offset         Int64,
    raw_body        String
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (metric_name, timestamp)
TTL timestamp + INTERVAL 90 DAY
```

#### Logs: raw storage

```sql
CREATE TABLE otel.logs_raw (
    timestamp       DateTime64(9),
    trace_id        String,
    span_id         String,
    trace_flags     UInt32,
    severity_text   String,
    severity_number Int32,
    body            String,
    resource_attributes Map(String, String),
    log_attributes  Map(String, String),
    
    ingested_at     DateTime64(3),
    _topic          String,
    _partition      Int32,
    _offset         Int64,
    raw_body        String
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (timestamp, trace_id)
TTL timestamp + INTERVAL 90 DAY
```

#### Materialized views for structured querying

Once raw OTel data is in ClickHouse, materialized views can extract structured fields for fast querying without parsing the full protobuf:

```sql
-- Traces view: extract common span attributes into columns
CREATE MATERIALIZED VIEW otel.traces_view TO otel.traces AS
SELECT
    timestamp,
    trace_id,
    span_id,
    parent_span_id,
    span_name,
    span_kind,
    service_name,
    resource_attributes,
    span_attributes,
    status_code,
    status_message,
    duration_ns,
    ingested_at
FROM otel.traces_raw;

-- (Actual CREATE would include parsing logic from raw_body)
```

For the initial implementation, the raw tables above are sufficient. How to decode OTLP Protobuf inside ClickHouse is covered in Section 5.

---

## 4. Redundancy and Flexibility

### 4.1 Pipeline Path Matrix

| Path | Latency | Durability | Use Case |
|------|---------|-----------|----------|
| App -> OTel Collector -> Kafka -> Vector -> CK | ~2-5s | Highest (Kafka buffer) | Primary: durable storage, replay |
| App -> OTel Collector -> Tempo/Prometheus | ~1-2s | No persistence | Real-time: trace search, dashboards |
| App -> OTel Collector -> CK (direct, no Kafka) | ~1-2s | Moderate | Emergency: Kafka unavailable |
| App logs -> Vector -> Kafka -> CK | ~2-5s | High | Legacy: non-OTel log sources |
| CK Kafka Engine (bypassing Vector) | ~2-5s | High | Fallback: Vector unavailable |

The first path is the primary. All others can be enabled or disabled independently without affecting the primary flow.

### 4.2 Failure Mode Isolation

| Failure | Effect on Primary Pipeline | Recovery |
|---------|---------------------------|----------|
| **App crashes** | Buffered spans in OTel SDK lost (up to ~2048 spans) | SDK flushes on graceful shutdown; ungraceful crash loses last batch |
| **OTel Collector down** | Spans buffer in app SDK; if app restarts before collector recovers, buffered spans lost | Auto-recovery: collector restart, SDK reconnects |
| **Kafka down** | OTel Collector kafka exporter retries; Tempo/Prometheus still work | Kafka restart; when back, collector resumes export; no data loss in collector's memory buffer (up to 512 MiB) |
| **Kafka disk full** | Producer stops; OTel Collector backs up; backpressure to app SDK | Free disk space or extend retention cleanup; consumer resumes |
| **Vector down** | Messages accumulate in Kafka (consumer lag grows) | Start Vector; it consumes from last committed offset; **no data loss** |
| **CK down** | Vector retries writes; Kafka consumer lag grows | CK restart; Vector drains backlog; **no data loss as long as Kafka retention covers the downtime** |
| **Network partition** | Depends on which links: if Kafka is reachable but CK is not, data queues in Kafka | When CK becomes reachable, Vector drains the backlog |

### 4.3 Flexibility: What Can Be Mixed and Matched

| Scenario | Configuration |
|----------|--------------|
| **No Kafka** (dev/single-node) | OTel Collector exports directly to CK via `clickhouse` exporter. Remove `kafka/*` exporters. |
| **No Vector** (small scale) | CK Kafka Engine tables consume directly from Kafka. Remove Vector from the pipeline. |
| **No Tempo** (cost-saving) | Remove `otlp/tempo` exporter from Collector config. Traces still flow through Kafka -> Vector -> CK. Query traces directly in CK via Grafana ClickHouse plugin. |
| **No Prometheus** (cost-saving) | Remove `prometheus` exporter. Metrics still flow through Kafka -> Vector -> CK. |
| **Multiple CK clusters** (multi-region) | Add a second Vector sink pointing to the second CK cluster. Both clusters receive the same data from Kafka. |
| **Add S3 backup** (archival) | Add an `aws_s3` sink to Vector. Data from Kafka -> Vector -> CK AND S3. |
| **Add Webhook alerting** | Add a `webhook` sink to Vector. Alerts trigger on specific metric thresholds. |

---

## 5. OTLP Protobuf in ClickHouse

The core challenge: OTel Collector exports OTLP Protobuf messages to Kafka, and we need to get them into ClickHouse in queryable form.

### Option A: Vector-side decoding (preferred long-term)

Vector uses a `wasm` or `lua` transform to decode OTLP Protobuf, extract fields, and emit structured JSON to CK.

**Pros**: CK sees clean structured data. No complex CK-side parsing.
**Cons**: Requires protobuf definitions in Vector. Adds transform complexity.

Status: Not yet available in Vector's VRL standard library. Tracked upstream.

### Option B: ClickHouse-side decoding with Protobuf format (initial implementation)

ClickHouse can parse Protobuf data on ingestion using its `Protobuf` format:

```sql
CREATE TABLE otel.traces_proto
(
    -- Define the ClickHouse schema matching the OTLP protobuf structure
    timestamp   DateTime64(9),
    trace_id    String,
    span_id     String,
    ...
) ENGINE = MergeTree
ORDER BY (trace_id, timestamp);

-- Vector sends raw protobuf bytes with Protobuf format specification
-- Vector config: encoding.codec = "protobuf"
-- with a .proto schema file
```

**However**: Vector's `clickhouse` sink with `encoding.codec = "protobuf"` requires a `.proto` schema file mapped to the table. This works but couples Vector to the protobuf schema.

### Option C: Store raw OTel Arrow / Parquet (future)

Apache Arrow-based OTel data (OTel Arrow exporter) can be stored in ClickHouse with the `Arrow` table engine or Parquet format. This is an experimental upstream project (`opentelemetry-arrow`).

### Recommendation: Start with Raw JSON in ClickHouse, Iterate

For the initial deployment:

1. **OTel Collector** serializes OTLP to JSON before exporting to Kafka (use `encoding: "json"` instead of `encoding: "otlp_proto"` in the kafka exporter).
2. **Vector** reads JSON from Kafka, adds metadata, writes to CK.
3. **CK** stores structured data in the raw tables defined in Section 3.4.

This sacrifices some Protobuf compactness but eliminates all decoding complexity. At our volume (~KB/day), the storage difference between Protobuf and JSON is irrelevant.

**Transition path**:
- Phase 1: OTLP -> JSON -> Kafka -> JSON in CK (prototype, get it working)
- Phase 2: OTLP -> Protobuf -> Kafka -> Protobuf in CK (if needed for performance)
- Phase 3: Vector-side protobuf decoding for structured columns (if VRL adds support)

Phase 1 config change in OTel Collector:

```yaml
exporters:
  kafka/traces:
    brokers: ["host.orb.internal:9092"]
    topic: "otlp.traces"
    encoding: "json"  # Changed from "otlp_proto"
```

This is a **zero-risk change**: only the encoding format changes. The pipeline topology stays the same.

---

## 6. Operational Playbook

### 6.1 Initial Deployment

#### Step 1: Create ClickHouse tables

```sql
CREATE DATABASE IF NOT EXISTS otel;

-- traces_raw
CREATE TABLE otel.traces_raw (
    timestamp DateTime64(9),
    trace_id String,
    span_id String,
    parent_span_id String,
    span_name String,
    span_kind Int32,
    service_name String,
    resource_attributes Map(String, String),
    span_attributes Map(String, String),
    status_code Int32,
    status_message String,
    events Array(Tuple( time_delta DateTime64(9), name String, attributes Map(String, String) )),
    links Array(Tuple( trace_id String, span_id String, trace_state String, attributes Map(String, String) )),
    duration_ns Int64,
    ingested_at DateTime64(3),
    _topic String,
    _partition Int32,
    _offset Int64,
    raw_body String
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (trace_id, timestamp)
TTL timestamp + INTERVAL 90 DAY;

-- metrics_raw
CREATE TABLE otel.metrics_raw (
    timestamp DateTime64(9),
    resource_attributes Map(String, String),
    metric_name String,
    metric_description String,
    metric_unit String,
    metric_type Int32,
    value_double Float64,
    value_int Int64,
    count Int64,
    sum Float64,
    min Float64,
    max Float64,
    bucket_bounds Array(Float64),
    bucket_counts Array(Int64),
    attributes Map(String, String),
    ingested_at DateTime64(3),
    _topic String,
    _partition Int32,
    _offset Int64,
    raw_body String
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (metric_name, timestamp)
TTL timestamp + INTERVAL 90 DAY;

-- logs_raw
CREATE TABLE otel.logs_raw (
    timestamp DateTime64(9),
    trace_id String,
    span_id String,
    severity_text String,
    severity_number Int32,
    body String,
    resource_attributes Map(String, String),
    log_attributes Map(String, String),
    ingested_at DateTime64(3),
    _topic String,
    _partition Int32,
    _offset Int64,
    raw_body String
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (timestamp, trace_id)
TTL timestamp + INTERVAL 90 DAY;
```

#### Step 2: Start Redpanda (if not already running)

```bash
docker run -d --name kyb-infra-redpanda \
  --restart unless-stopped \
  --network kyb-infra \
  -p 9092:9092 -p 9644:9644 \
  -v kafka_data:/var/lib/redpanda/data \
  docker.redpanda.com/redpandadata/redpanda:latest \
  redpanda start --mode dev-container \
    --kafka-addr PLAINTEXT://0.0.0.0:9092 \
    --advertise-kafka-addr PLAINTEXT://host.orb.internal:9092

# Create OTel topics
rpk topic create otlp.traces  --partitions 3
rpk topic create otlp.metrics --partitions 2
rpk topic create otlp.logs    --partitions 2
```

#### Step 3: Start OTel Collector

```bash
docker run -d --name kyb-infra-otel-collector \
  --restart unless-stopped \
  --network kyb-infra \
  -p 4317:4317 -p 4318:4318 \
  -v otel-collector-config:/etc/otel-collector \
  otel/opentelemetry-collector-contrib:latest
```

Place the config YAML at the mounted config path and restart.

#### Step 4: Start Vector

```bash
docker run -d --name kyb-infra-vector \
  --restart unless-stopped \
  --network kyb-infra \
  -v vector-config:/etc/vector \
  timberio/vector:latest
```

#### Step 5: Verify

```bash
# Check containers are running
docker ps | grep -E 'redpanda|otel-collector|vector'

# Send a test span
curl -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{
    "resourceSpans": [{
      "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "test"}}]},
      "scopeSpans": [{
        "scope": {"name": "test"},
        "spans": [{
          "traceId": "0af7651916cd43dd8448eb211c80319c",
          "spanId": "b7ad6b7169203331",
          "name": "test-span",
          "kind": 1,
          "startTimeUnixNano": "1650000000000000000",
          "endTimeUnixNano": "1650000001000000000"
        }]
      }]
    }]
  }'

# Check CK for the test span
clickhouse-client --host host.orb.internal --query "SELECT count(*) FROM otel.traces_raw"

# Check Kafka topic
rpk topic consume otlp.traces --num 1
```

### 6.2 Production Runbook

#### Daily checks

```bash
# 1. All containers running
docker ps --filter "name=kyb-infra-.*" --format "table {{.Names}}\t{{.Status}}"

# 2. Kafka consumer lag (Vector consumer groups)
rpk group list
rpk group describe vector-ck-traces --summary
rpk group describe vector-ck-metrics --summary
rpk group describe vector-ck-logs --summary

# 3. Recent data in CK
clickhouse-client --host host.orb.internal --query "
  SELECT 'traces', count(), max(timestamp)
  FROM otel.traces_raw
  WHERE timestamp > now() - INTERVAL 5 MINUTE
  UNION ALL
  SELECT 'metrics', count(), max(timestamp)
  FROM otel.metrics_raw
  WHERE timestamp > now() - INTERVAL 5 MINUTE
  UNION ALL
  SELECT 'logs', count(), max(timestamp)
  FROM otel.logs_raw
  WHERE timestamp > now() - INTERVAL 5 MINUTE
"
```

#### Troubleshooting

| Symptom | Check | Fix |
|---------|-------|-----|
| No data in CK `otel.*` tables | 1. OTel Collector logs: `docker logs kyb-infra-otel-collector --tail 20` | Restart collector or fix config |
| | 2. Kafka messages: `rpk topic consume otlp.traces --num 5` | If empty: collector's kafka exporter is not producing |
| | 3. Vector logs: `docker logs kyb-infra-vector --tail 20` | If Kafka has data but Vector is not consuming: check Vector config |
| Kafka consumer lag growing | 1. CK reachable? `clickhouse-client --host host.orb.internal --query "SELECT 1"` | Restart CK |
| | 2. Vector running? `docker ps` | Restart Vector |
| | 3. Vector OOM? `docker logs kyb-infra-vector --tail 10` | Increase Vector memory limit |
| OTel Collector OOM | 1. Check `memory_limiter` processor logs | Reduce `limit_mib` or add more memory |
| | 2. Check producer volume | Add sampling in the OTel SDK |

#### Recovery procedures

**Full pipeline recovery after CK outage**:

```bash
# 1. CK is back up
# 2. Check how far behind Vector is
rpk group describe vector-ck-traces
# 3. Vector will automatically resume from last committed offset
# 4. Monitor catch-up speed:
watch -n 10 "rpk group describe vector-ck-traces --summary"
# 5. Verify row counts once consumer lag is 0
```

**Full Kafka rebuild (disk loss)**:

```bash
# 1. CK has all previously consumed data (up to 90d)
# 2. Only data that was in Kafka but not yet consumed by Vector is lost
# 3. Restart Redpanda, recreate topics, restart Vector
# 4. Vector starts from latest offset (no replay possible)
# 5. Data loss window = time between CK last consumption and Kafka failure
```

---

## 7. Volume Estimates

### 7.1 Trace Volume

At ~90 messages/day, ~6 spans/message:

| Item | Daily | 90 days |
|------|-------|---------|
| Spans | 540 | 48,600 |
| Raw trace data (JSON) | ~500 KB | ~45 MB |
| Compressed (CK columnar) | ~100 KB | ~9 MB |

### 7.2 Metric Volume

Per cc-connect metric, ~10 counter/histogram data points per message:

| Item | Daily | 90 days |
|------|-------|---------|
| Data points | ~900 | 81,000 |
| Raw metric data (JSON) | ~200 KB | ~18 MB |
| Compressed | ~50 KB | ~4.5 MB |

### 7.3 Log Volume (OTel, once cc-connect migrates)

| Item | Daily | 90 days |
|------|-------|---------|
| Log records | ~200 (structured, not every line) | 18,000 |
| Raw log data (JSON) | ~100 KB | ~9 MB |
| Compressed | ~30 KB | ~2.7 MB |

### 7.4 Kafka Retention

| Topic | 7-day uncompressed | 7-day compressed | 14-day compressed |
|-------|-------------------|------------------|-------------------|
| `otlp.traces` | ~3.5 MB | ~700 KB | N/A |
| `otlp.metrics` | ~1.4 MB | ~350 KB | ~700 KB |
| `otlp.logs` | ~700 KB | ~200 KB | N/A |
| **Total** | **~5.6 MB** | **~1.25 MB** | |

All negligible. No scaling concerns for the foreseeable future.

---

## 8. Migration Path

### Phase 0: Current State

```
cc-connect -> Vector -> CK (direct, cc.message_log)
cc-connect -> OTel Collector -> Tempo (traces only, no persistence)
```

### Phase 1: Deploy Kafka Bus + OTel Pipeline (parallel)

1. Deploy Redpanda (if not already running from Kafka Message Bus design)
2. Deploy OTel Collector with Kafka exporters + Tempo fan-out
3. Create `otlp.*` topics
4. Deploy Vector with Kafka sources + CK sinks
5. Create `otel.*` tables in CK
6. Keep existing pipelines running unchanged

```
cc-connect -> Vector -> CK (existing, untouched)
cc-connect -> OTel Collector -> Tempo (existing, untouched)
cc-connect -> OTel Collector -> Kafka -> Vector -> CK (new)
```

### Phase 2: Verify and Switch

1. Run Kafka-sourced and direct-sourced pipelines side by side for 24h
2. Compare row counts between `cc.message_log` (direct) and `otel.logs_raw` (Kafka-sourced)
3. Produce test spans from a development session; verify they appear in both Tempo and CK
4. Switch Grafana dashboards to `otel.*` tables
5. Remove Vector's direct CK sink; Vector now only reads from Kafka

```
cc-connect -> OTel Collector -> Kafka -> Vector -> CK (primary)
cc-connect -> OTel Collector -> Tempo (real-time, side channel)
```

### Phase 3: Instrumentation Upgrade

1. Add OTel SDK traces/metrics to patrol agents (Ruby OTel SDK)
2. Add OTel SDK to cc-connect's tool execution and permission flow (Phase 1-2 of `otel-cc-connect.md`)
3. Remove legacy Vector docker_logs source for cc-connect
4. cc-connect stops writing `slog` lines to stdout (or at least stops relying on them for observability)

### Phase 4: Full OTel

```
cc-connect (native OTel) ──► OTel Collector ──► Kafka ──► Vector ──► CK
patrol (native OTel)     ──► OTel Collector ──► Kafka ──► Vector ──► CK
future apps (native OTel)──► OTel Collector ──► Kafka ──► Vector ──► CK
                                                                  ──► Tempo (traces)
                                                                  ──► Prometheus (metrics)

Legacy topics removed:
  cc.events    ── replaced by otlp.logs + otlp.traces
  patrol.events ── replaced by otlp.metrics + otlp.logs
```

---

## 9. Alternatives Considered

### 9.1 Grafana LGTM Stack (Loki + Grafana + Tempo + Mimir)

The Grafana Lab's LGTM stack is the "batteries-included" alternative:
- **Loki** for logs (instead of CK)
- **Tempo** for traces (already planned)
- **Mimir** for metrics (instead of CK + Prometheus)
- **Grafana** for visualization

**Not chosen because:**
- We already have ClickHouse running for bridge data. Adding Loki and Mimir doubles the infra footprint.
- ClickHouse handles logs, traces, and metrics well with the right schema.
- The team already knows ClickHouse SQL. Adding PromQL and LogQL is extra cognitive load.
- LGTM is designed for cloud-scale (TBs/day). Our volume (~MB/day) does not justify the overhead.

### 9.2 Direct OTel Collector -> ClickHouse (no Kafka)

The OTel Collector has a ClickHouse exporter (`clickhouse` exporter in contrib). Why not skip Kafka entirely?

**Not chosen because:**
- No replay: if CK ingestion fails, data is lost (OTel Collector's batch processor has limited memory).
- No backpressure isolation: CK backpressure would block the OTel Collector, affecting all pipelines.
- No multi-consumer: if you want both CK and S3, the Collector must dual-export (possible, but adds complexity in the collector config).
- Kafka adds ~2s of latency. At our volume, this is irrelevant. The durability benefits outweigh it.

### 9.3 Vector -> CK (current approach, no Kafka, no OTel)

The current approach works for Docker logs. But it has no tracing, no OTel metrics, and no structured schema governance.

### 9.4 CK Kafka Engine (no Vector)

CK can consume Kafka topics natively (as designed in `kafka-message-bus.md`). Why add Vector?

**Vector adds:**
- Transform capability (decode protobuf, enrich, filter, route)
- Multi-sink (CK + S3 + webhook + alerting)
- Retry/backpressure logic independent of CK
- Observability into the pipeline itself (Vector internal metrics)

**When to skip Vector**: If you only need CK sink and the data is already in the right format (e.g., structured JSON), CK Kafka Engine is simpler. For the OTel pipeline, however, the protobuf decoding and enrichment requirements justify Vector.

### 9.5 Fluentd / Fluent Bit instead of Vector

Vector and Fluent Bit are similar tools. Vector was chosen because:
- It is already in use in this project (cc-connect log shipping).
- VRL is more expressive than Fluent Bit's filter chain.
- Better ClickHouse sink support.

---

## 10. Future Considerations

### 10.1 OTel Operator (Kubernetes)

If this project moves to Kubernetes, the OpenTelemetry Operator can manage the OTel Collector deployment, including:
- Sidecar injection for instrumented apps
- Automatic config reload
- Service mesh integration

### 10.2 Sampling Strategies

At current volume, head-based sampling at 100% is fine. If volume grows:

1. **Probabilistic sampling** in the OTel Collector: drop 90% of spans at the head.
2. **Tail-based sampling**: keep a second OTel Collector pipeline that evaluates spans after completion, keeping slow/error spans and dropping fast/healthy ones.

### 10.3 Span Links for Cross-System Traces

When cc-connect interacts with external systems (Claude API, Feishu API) that support W3C Trace Context, span links can connect traces across trust boundaries. Neither Claude nor Feishu currently support this, but the OTel pipeline is ready for it when they do.

### 10.4 Automated Grafana Dashboard Provisioning

Once the pipeline is running, Grafana dashboards can be provisioned from JSON:
- Trace explorer (Tempo datasource for real-time, CK datasource for historical)
- Metric dashboards (Prometheus for real-time, CK for historical)
- Log dashboard (CK datasource)
- Pipeline health dashboard (Vector internal metrics -> CK)

---

## 11. Related Documents

- `docs/infra/reviews/otel-cc-connect.md` -- OTel span model for cc-connect (trace schema, attributes, context propagation)
- `docs/infra/reviews/kafka-message-bus.md` -- Kafka bus for observability events (producer patterns, CK Kafka Engine integration)
- `docs/infra/observability-design.md` -- Current observability architecture overview
- `docs/infra/designs/bridge-ck-ingestion.md` -- Existing Vector -> CK pipeline
- `docs/infra/reviews/review-bridge-ck-ingestion-A*.md` -- Reviews of the existing pipeline
- OpenTelemetry Collector Kafka exporter: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/kafkaexporter
- Vector Kafka source: https://vector.dev/docs/reference/configuration/sources/kafka/
- Vector ClickHouse sink: https://vector.dev/docs/reference/configuration/sinks/clickhouse/
