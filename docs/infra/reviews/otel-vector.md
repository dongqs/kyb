---
decision: 稍微有点不确定等专家再审一轮
---

# OTel + Vector Combined Pipeline

**Status**: Design proposal
**Date**: 2026-05-23
**Scope**: Unified observability pipeline combining OTel Collector for protocol ingestion and Vector for enrichment, routing, and ClickHouse delivery. Covers trace, metric, and log signals from all instrumented services.

---

## 1. Motivation

### Current state

The infrastructure currently has **three independent observability pipelines**, each with its own producer, transport, and storage:

| Pipeline | Producer | Transport | Storage | Enrichment |
|----------|----------|-----------|---------|------------|
| Message logs | cc-connect (structured stdout) | Docker logs -> Vector | `cc.message_log` (CK) | None (raw log line) |
| Claude hooks | Claude Code (hook events) | Shell script -> HTTP POST | `kyb.claude_hook_events` (CK) | Bash script adds hostname, PID, proxy flag |
| Docker events | docker-event-watcher | Shell script -> HTTP POST | `infra.docker_events` (CK) | Python inline on each event |

An additional pipeline is **designed but not yet deployed** (see `docs/infra/reviews/otel-cc-connect.md`):

| Pipeline | Producer | Transport | Storage | Enrichment |
|----------|----------|-----------|---------|------------|
| cc-connect traces | cc-connect (OTel SDK) | OTLP -> OTel Collector -> Tempo + Prometheus | Tempo (traces), Prometheus (metrics) | Collector batch/memory_limiter only |

### Problems

1. **No enrichment layer** -- Each pipeline duplicates metadata injection (hostname, cluster, environment). There is no centralized place to add, normalize, or redact fields before storage.

2. **No unified schema** -- Cross-pipeline correlation requires ad-hoc joins across tables with incompatible column types and naming conventions.

3. **Point-to-point brittleness** -- Every producer knows its destination. If CK moves or a new destination is needed (Kafka, S3 archive), every producer must be reconfigured.

4. **Inconsistent OTel support** -- The OTel collector design only handles traces. Metrics go to Prometheus (separate storage). Logs are unaddressed. There is no unified OTel pipeline for all three signals.

5. **No routing** -- Events cannot be selectively duplicated, sampled, or redirected based on content. All-or-nothing per producer.

### Goals

1. **Unified ingestion** -- A single OTLP endpoint for all OTel-instrumented services.
2. **Centralized enrichment** -- Vector VRL transforms for metadata injection, field normalization, PII redaction.
3. **Content-aware routing** -- Route by signal type (trace/metric/log), service name, or attribute value to different CK tables or external backends.
4. **Backpressure isolation** -- OTel Collector absorbs client backpressure; Vector absorbs CK backpressure. Producers are isolated from storage failures.
5. **Extensible** -- Adding a new destination (Kafka, S3, Tempo) requires only a new Vector sink, no producer changes.

---

## 2. Architecture

```
┌──────────────────────┐   OTLP (gRPC/HTTP)   ┌──────────────────────┐
│  OTel-instrumented   │ ────────────────────> │   OTel Collector     │
│  services            │   port 4317 / 4318    │   (otel-collector)   │
│                      │                       │                      │
│  - cc-connect        │                       │  Receiver: OTLP      │
│  - Claude Code       │                       │  Processor: batch,   │
│  - Patrol (future)   │                       │    memory_limiter    │
│  - Boss (future)     │                       │  Exporter: OTLP      │
└──────────────────────┘                       └──────────┬───────────┘
                                                          │
                                                          │ OTLP (gRPC)
                                                          │ port 4319
                                                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Vector                                                               │
│                                                                      │
│  Source: opentelemetry (port 4319, gRPC)                             │
│                                                                      │
│  Transforms (VRL):                                                    │
│    ┌──────────────┐  ┌──────────────┐  ┌─────────────────────────┐  │
│    │ enrich       │  │ normalize    │  │ route_by_signal         │  │
│    │ - cluster    │  │ - attr names │  │ - trace -> spans table  │  │
│    │ - env        │  │ - enum       │  │ - metric -> metrics tbl │  │
│    │ - host       │  │   mapping    │  │ - log   -> logs table   │  │
│    │ - container  │  │ - unit conv  │  └─────────────────────────┘  │
│    └──────────────┘  └──────────────┘                                │
│                                                                      │
│  Sinks:                                                              │
│    ┌────────────────────┐  ┌──────────────────┐  ┌──────────────┐   │
│    │ ClickHouse (traces)│  │ ClickHouse (met.) │  │ CK (logs)    │   │
│    │ query: INSERT INTO │  │ INSERT INTO       │  │ INSERT INTO  │   │
│    │   otel_spans       │  │   otel_metrics    │  │ otel_logs    │   │
│    └────────────────────┘  └──────────────────┘  └──────────────┘   │
│                                                                      │
│    ┌────────────────────┐  ┌─────────────────────────────┐          │
│    │ Kafka (future)     │  │ Tempo (optional, via syslog │          │
│    │ topic: otel.events │  │   or secondary CK export)  │          │
│    └────────────────────┘  └─────────────────────────────┘          │
└──────────────────────────────────────────────────────────────────────┘
                                                          │
                                                          ▼
                                                  ┌──────────────┐
                                                  │  ClickHouse   │
                                                  │              │
                                                  │ otel_spans   │
                                                  │ otel_metrics │
                                                  │ otel_logs    │
                                                  └──────────────┘
```

### Component roles

| Component | Role |
|-----------|------|
| **OTel Collector** | OTLP protocol gateway. Terminates client gRPC/HTTP connections, applies global batching and memory limiting, forwards to Vector. Single point of contact for all OTel-instrumented services. |
| **Vector** | Enrichment and routing engine. Receives OTLP from collector, transforms events via VRL, routes to destination-specific sinks. All business logic (enrichment, normalization, routing) lives here. |
| **ClickHouse** | Unified long-term storage. Separate tables per signal type (trace/metric/log) with consistent column naming and shared enrichment fields across tables. |

### Deployment topology

OTel Collector and Vector run as separate containers, deployed once (on the Mac/Orbstack super-boss where CK lives):

```
Container: otel-collector
  Ports:   4317 (gRPC from apps), 4318 (HTTP from apps)
  Config:  /etc/otel-collector-config.yaml
  Image:   otel/opentelemetry-collector-contrib:0.120.0

Container: vector
  Ports:   4319 (gRPC from collector, internal only)
  Config:  /etc/vector/vector.toml
  Image:   timberio/vector:0.44.0
  Env:     CLUSTER_NAME=mac-orbstack, ENVIRONMENT=production
```

A single deployment is sufficient at current scale (<100 events/day). Multi-cluster deployment (one per boss) is a future optimization when cross-cluster OTel data becomes significant.

### Why two stages instead of direct Vector OTLP?

Vector's `opentelemetry` source can receive OTLP directly. The two-stage architecture adds value at this project's scale:

1. **Protocol separation** -- Collector handles OTLP spec compliance (gRPC, HTTP/protobuf, HTTP/JSON). Vector handles data logic. This mirrors the OTel project's own recommended pattern: Collector as gateway, backend as pipeline.

2. **Backpressure isolation** -- If Vector restarts (config change, version upgrade), the Collector buffers/drops gracefully. If Collector restarts, the apps retry via SDK. Neither restart propagates to the other.

3. **Observability of observability** -- Collector exports its own metrics (via `telemetry` setting). Vector also self-monitors. Two-stage means we can detect which stage is failing.

4. **Fan-out without burdening apps** -- Adding Tempo or Kafka later requires only a Collector exporter change, not an SDK change in every app.

---

## 3. Data Flow

### 3.1 Trace flow

```
OTel SDK (cc-connect)
  │
  │ OTLP gRPC :4317  (trace_id=abc, span_name="feishu.message.receive", ...)
  ▼
OTel Collector
  │ batch (1s / 1024 items)
  │ memory_limiter (512 MiB)
  │ OTLP gRPC :4319  (same payload, batched)
  ▼
Vector: opentelemetry source
  │ kind = "trace"
  │ .trace_id, .span_id, .parent_span_id, .name, .kind, .status,
  │ .attributes = {feishu.msg_id: "om_xxx", ...},
  │ .resource.attributes = {service.name: "cc-connect", ...}
  │ .duration_ns (nanoseconds)
  │
  │ VRL enrich: add .cluster, .environment, .service_name (extracted)
  │ VRL normalize: rename .attributes["feishu.msg_id"] -> .msg_id for CK column match
  │
  ▼
Vector: route_by_signal
  │ .kind == "trace" -> clickhouse_traces sink
  ▼
Vector: clickhouse sink (otel_spans table)
```

### 3.2 Metric flow

```
OTel SDK (cc-connect)
  │ OTLP gRPC :4317  (metric name="cc.messages.received",
  │                   sum, value=42, attributes={chat_type: "group"})
  ▼
OTel Collector -> batch -> OTLP gRPC :4319
  ▼
Vector: opentelemetry source
  │ kind = "metric"
  │ .name = "cc.messages.received"
  │ .kind = "sum"  (or "gauge", "histogram")
  │ .value = 42
  │ .attributes = {chat_type: "group"}
  │ .resource.attributes = {service.name: "cc-connect"}
  │
  │ VRL enrich: .cluster, .environment, .service_name
  │ VRL for histograms: flatten buckets into summary stats
  │   (or skip histograms and send raw + bucket fields)
  │
  ▼
Vector: route_by_signal -> clickhouse_metrics sink
  ▼
ClickHouse: otel_metrics table
```

### 3.3 Log flow

```
OTel SDK (cc-connect, or any app with OTel logging)
  │ OTLP gRPC :4317  (body="turn complete", severity=INFO,
  │                   attributes={msg_id: "om_xxx", turn_duration: "4.2s"})
  ▼
OTel Collector -> batch -> OTLP gRPC :4319
  ▼
Vector: opentelemetry source
  │ kind = "log"
  │ .body = "turn complete"
  │ .severity = "INFO"
  │ .attributes = {...}
  │ .resource.attributes = {...}
  │
  │ VRL enrich: .cluster, .environment, .service_name
  │
  ▼
Vector: route_by_signal -> clickhouse_logs sink
  ▼
ClickHouse: otel_logs table
```

---

## 4. Configuration

### 4.1 OTel Collector (`otel-collector-config.yaml`)

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
    spike_limit_mib: 128

exporters:
  otlp/vector:
    endpoint: vector:4319
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
      initial_interval: 1s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 2
      queue_size: 100

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/vector]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/vector]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/vector]

  telemetry:
    metrics:
      level: detailed
    logs:
      level: info
```

Design notes:

- **No sampling processor** -- At current volume (<100 traces/day), sampling would lose data for no gain. Add a `probabilistic_sampler` when daily span count exceeds 100K.
- **Single exporter** (otlp/vector) -- All signals go to Vector. The collector does not fan out; Vector does.
- **sending_queue** -- 100-element queue absorbs Vector restarts. If Vector is down for >5 minutes, events are dropped (acceptable at current volume).
- **insecure TLS** -- Internal network between collector and Vector containers. No TLS needed. Use mTLS if deploying across cluster boundaries.

### 4.2 Vector (`vector.toml`)

```toml
[api]
enabled = true
address = "0.0.0.0:8686"
playground = false

# ── Source: OTel from Collector ──────────────────────────────────────

[sources.otel]
type = "opentelemetry"
address = "0.0.0.0:4319"
# gRPC only (internal). No HTTP endpoint needed between collector and vector.

# ── Transforms ────────────────────────────────────────────────────────

[transforms.enrich]
type = "remap"
inputs = ["otel"]
source = """
# -- Deployment context (from env vars set in container) --
.cluster = get_env_var!("CLUSTER_NAME") ?? "unknown"
.environment = get_env_var!("ENVIRONMENT") ?? "production"

# -- Extract service name from resource attributes --
.service_name = .resource.attributes["service.name"] ?? "unknown"

# -- Extract host name if available --
.host_name = .resource.attributes["host.name"] ??
             .resource.attributes["host.hostname"] ??
             ""

# -- Extract container_id --
.container_id = .resource.attributes["container.id"] ?? ""

# -- Standardize timestamp to DateTime64 --
if exists(.timestamp) {
  .timestamp = to_unix_timestamp!(.timestamp)
}

# -- Normalize signal kind --
# Vector's opentelemetry source sets .kind to "trace", "metric", or "log"
# We keep this as the routing key.
.signal = .kind
"""

# ── Normalize span attributes ────────────────────────────────────────

[transforms.normalize_trace]
type = "remap"
inputs = ["enrich"]
source = """
# Only process trace signals
if .signal != "trace" {
  abort
}

# -- Extract common span attributes to top-level fields for CK indexing --
.span_name = .name ?? ""
.span_kind = .kind ?? ""
.status_code = .status.code ?? "Unset"
.status_message = .status.message ?? ""

# -- Rename duration_ns to duration_nanos for consistency --
if exists(.duration_ns) {
  .duration_nanos = .duration_ns
}

# -- Extract feishu-specific attributes from the attributes map --
# OTel attributes arrive as a map. Pull specific keys to top-level.
if exists(.attributes["feishu.msg_id"]) {
  .feishu_msg_id = del(.attributes["feishu.msg_id"])
}
if exists(.attributes["feishu.chat_id"]) {
  .feishu_chat_id = del(.attributes["feishu.chat_id"])
}
if exists(.attributes["cc.session"]) {
  .cc_session = del(.attributes["cc.session"])
}
if exists(.attributes["claude.response.input_tokens"]) {
  .input_tokens = to_int!(del(.attributes["claude.response.input_tokens"])) ?? 0
}
if exists(.attributes["claude.response.output_tokens"]) {
  .output_tokens = to_int!(del(.attributes["claude.response.output_tokens"])) ?? 0
}

# -- Preserve remaining attributes as a Map(String, String) --
# ClickHouse expects map values as strings. Convert all values.
.attributes = map_values!(.attributes) ?? {}
.span_attributes = .attributes

# -- Clean up intermediate fields --
del(.name)
del(.kind)
"""

[transforms.normalize_metric]
type = "remap"
inputs = ["enrich"]
source = """
if .signal != "metric" {
  abort
}

# -- Extract fields --
.metric_name = .name ?? ""
.metric_type = .kind ?? ""
.metric_value = .value ?? 0.0
.tags = map_values!(.attributes) ?? {}

del(.name)
del(.kind)
del(.value)
del(.attributes)
"""

[transforms.normalize_log]
type = "remap"
inputs = ["enrich"]
source = """
if .signal != "log" {
  abort
}

# -- Extract fields --
if exists(.body) {
  .body = to_string(.body) ?? ""
}
.severity_text = .severity ?? "INFO"
.severity_number = .severity_number ?? 9

del(.severity)
del(.severity_number)
"""

# ── Routing (by signal type) ─────────────────────────────────────────

[transforms.route_by_signal]
type = "route"
inputs = ["normalize_trace", "normalize_metric", "normalize_log"]
route.traces = '.signal == "trace"'
route.metrics = '.signal == "metric"'
route.logs = '.signal == "log"'

# ── Sinks: ClickHouse ────────────────────────────────────────────────

[sinks.clickhouse_traces]
type = "clickhouse"
inputs = ["route_by_signal.traces"]
endpoint = "http://clickhouse:8123"
database = "kyb"
table = "otel_spans"
encoding = "json"
healthcheck = true
batch_timeout_secs = 2
batch_max_events = 1000

[sinks.clickhouse_metrics]
type = "clickhouse"
inputs = ["route_by_signal.metrics"]
endpoint = "http://clickhouse:8123"
database = "kyb"
table = "otel_metrics"
encoding = "json"
healthcheck = true
batch_timeout_secs = 2
batch_max_events = 1000

[sinks.clickhouse_logs]
type = "clickhouse"
inputs = ["route_by_signal.logs"]
endpoint = "http://clickhouse:8123"
database = "kyb"
table = "otel_logs"
encoding = "json"
healthcheck = true
batch_timeout_secs = 2
batch_max_events = 1000
```

### 4.3 VRL enrichment reference

The enrichment transform (`enrich`) applies to all signals. Fields added:

| Field | Source | Example | Purpose |
|-------|--------|---------|---------|
| `.cluster` | env var `CLUSTER_NAME` | `mac-orbstack` | Multi-cluster correlation |
| `.environment` | env var `ENVIRONMENT` | `production` | Environment filtering in dashboards |
| `.service_name` | resource attr `service.name` | `cc-connect` | Service identification |
| `.host_name` | resource attr `host.name` | `kyb-infra-boss` | Host-level debugging |
| `.container_id` | resource attr `container.id` | `abc123def456` | Container-level debugging |
| `.signal` | opentelemetry source `.kind` | `trace` | Routing key |

---

## 5. ClickHouse Schema

### 5.1 `kyb.otel_spans`

Stores individual spans from distributed traces.

```sql
CREATE TABLE kyb.otel_spans (
    -- Identity
    timestamp           DateTime64(9),
    trace_id            String,
    span_id             String,
    parent_span_id      String DEFAULT '',
    trace_state         String DEFAULT '',

    -- Span metadata
    span_name           String,
    span_kind           LowCardinality(String),
    status_code         LowCardinality(String),   -- Unset / Ok / Error
    status_message      String DEFAULT '',
    duration_nanos      UInt64,

    -- Service context (extracted from resource attributes)
    service_name        LowCardinality(String),

    -- Attributes (flattened)
    feishu_msg_id       String DEFAULT '',
    feishu_chat_id      String DEFAULT '',
    cc_session          String DEFAULT '',
    input_tokens        UInt32 DEFAULT 0,
    output_tokens       UInt32 DEFAULT 0,

    -- Remaining attributes as KV map
    span_attributes     Map(String, String) DEFAULT {},

    -- Span events (annotations)
    span_events         Array(Tuple(
        event_timestamp DateTime64(9),
        event_name     String,
        event_attributes Map(String, String)
    )) DEFAULT [],

    -- Enriched fields
    cluster             LowCardinality(String),
    environment         LowCardinality(String),
    host_name           String DEFAULT '',
    container_id        String DEFAULT '',

    -- Ingestion metadata
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), service_name, trace_id)
PARTITION BY toDate(timestamp)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### 5.2 `kyb.otel_metrics`

Stores individual metric data points (sum, gauge, histogram).

```sql
CREATE TABLE kyb.otel_metrics (
    timestamp           DateTime64(9),
    service_name        LowCardinality(String),
    metric_name         String,
    metric_type         LowCardinality(String),   -- sum / gauge / histogram
    metric_value        Float64,

    -- For histogram: bucket data
    histogram_count     UInt64 DEFAULT 0,
    histogram_sum       Float64 DEFAULT 0,
    histogram_buckets   Array(Tuple(
        bucket_boundary Float64,
        bucket_count    UInt64
    )) DEFAULT [],

    -- Tags (from OTel attributes)
    tags                Map(String, String) DEFAULT {},

    -- Enriched fields
    cluster             LowCardinality(String),
    environment         LowCardinality(String),
    host_name           String DEFAULT '',
    container_id        String DEFAULT '',

    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), service_name, metric_name)
PARTITION BY toDate(timestamp)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### 5.3 `kyb.otel_logs`

Stores OTel log records.

```sql
CREATE TABLE kyb.otel_logs (
    timestamp           DateTime64(9),
    trace_id            String DEFAULT '',
    span_id             String DEFAULT '',
    severity_text       LowCardinality(String),   -- INFO / WARN / ERROR
    severity_number     UInt8 DEFAULT 9,          -- 9=INFO, 13=WARN, 17=ERROR (OTel semantic convention)
    body                String,

    -- Context
    service_name        LowCardinality(String),
    log_attributes      Map(String, String) DEFAULT {},

    -- Enriched fields
    cluster             LowCardinality(String),
    environment         LowCardinality(String),
    host_name           String DEFAULT '',
    container_id        String DEFAULT '',

    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), service_name, severity_text)
PARTITION BY toDate(timestamp)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### 5.4 Schema design decisions

1. **Separate tables per signal** -- Traces, metrics, and logs have fundamentally different schemas. A unified table would waste columns and complicate partitioning. Separate tables enable per-signal TTL and indexing.

2. **`Map(String, String)` for attributes** -- OTel attributes are arbitrary KV pairs per span/metric/log. ClickHouse `Map` type stores them without schema changes. Queries use `arrayExists()` or `mapContains()` for attribute-based filtering.

3. **Specific columns for common attributes** -- `feishu_msg_id`, `cc_session`, `input_tokens`, `output_tokens` are extracted to top-level columns because they are frequently queried and benefit from indexing. The `Map` holds everything else.

4. **Partition + TTL by day** -- At current volume (<100 spans/day), partitioning is unnecessary but harmless. It enables time-range pruning for future volume growth. 90-day retention matches existing `cc.message_log` policy.

5. **`DateTime64(9)` for nanosecond precision** -- OTel timestamps are nanosecond-granularity. ClickHouse `DateTime64(9)` stores them losslessly. For queries, `toDate(timestamp)` truncates for daily aggregation.

6. **`_ingested_at` separate from `timestamp`** -- Event time vs. ingestion time. The gap measures pipeline latency.

---

## 6. Routing Logic

Routing happens in two stages:

### Stage 1: Signal-based routing (Vector `route` transform)

The `route_by_signal` transform splits the unified OTel stream into three branches:

| Route condition | Output stream | Sink |
|-----------------|---------------|------|
| `.signal == "trace"` | `route_by_signal.traces` | `clickhouse_traces` |
| `.signal == "metric"` | `route_by_signal.metrics` | `clickhouse_metrics` |
| `.signal == "log"`    | `route_by_signal.logs`   | `clickhouse_logs`   |

### Stage 2: Attribute-based routing (future)

Add route conditions for special handling:

```toml
[transforms.route_by_signal]
type = "route"
inputs = ["normalize_trace", "normalize_metric", "normalize_log"]
route.traces = '.signal == "trace"'
route.metrics = '.signal == "metric"'
route.logs = '.signal == "log"'
route.errors = '.status_code == "Error"'   # Error spans → alerting pipeline
route.high_latency = '.duration_nanos > 30_000_000_000'  # Spans >30s
```

Error and high-latency routes would feed into separate sinks: a secondary CK table for fast alert queries, or a webhook sink for Feishu alerts.

### Dropped events

Events that fail all route conditions are dropped. Vector logs a warning for unmatched events (configurable via `dropped_behavior` in the route transform). At current volume, unmatched events indicate a misconfiguration or unsupported signal type.

---

## 7. Deployment

### 7.1 Container definitions

```bash
# OTel Collector
docker run -d \
  --name otel-collector \
  --restart unless-stopped \
  --network kyb-infra \
  --init \
  -p 4317:4317 \
  -p 4318:4318 \
  -v /home/dev/otel-collector-config.yaml:/etc/otel-collector-config.yaml \
  otel/opentelemetry-collector-contrib:0.120.0 \
  --config /etc/otel-collector-config.yaml

# Vector
docker run -d \
  --name vector \
  --restart unless-stopped \
  --network kyb-infra \
  --init \
  -p 4319:4319 \
  -p 8686:8686 \
  -v /home/dev/vector.toml:/etc/vector/vector.toml:ro \
  -e CLUSTER_NAME=mac-orbstack \
  -e ENVIRONMENT=production \
  timberio/vector:0.44.0 \
  --config /etc/vector/vector.toml
```

### 7.2 Network

Both containers join the `kyb-infra` Docker network (shared with ClickHouse and existing infra containers). Service discovery uses Docker DNS:

- `otel-collector:4317` -- OTLP gRPC endpoint for instrumented services
- `otel-collector:4318` -- OTLP HTTP endpoint for instrumented services
- `vector:4319` -- Collector-to-Vector OTLP (internal, not exposed)

### 7.3 Storage

Neither container needs persistent volumes. OTel Collector queues in memory (dropped on restart). Vector is stateless (events buffered in memory). The only stateful component is ClickHouse, which already has persistent storage.

### 7.4 Startup order

```
ClickHouse    (already running)
    ↓
Vector        (starts after CK, validates CK healthcheck on startup)
    ↓
OTel Collector  (starts after Vector, OTLP gRPC to vector:4319)
    ↓
Instrumented services  (OTLP to otel-collector:4317)
```

In practice, dependencies are soft: Vector and Collector will retry connections automatically. The healthcheck setting in Vector's ClickHouse sink will log warnings (not crash) if CK is unavailable.

### 7.5 OTel SDK configuration for instrumented services

Services already instrumented with OTel SDK point their OTLP exporter to the collector:

```go
// cc-connect OTLP exporter configuration
exporter, err := otlptracegrpc.New(ctx,
    otlptracegrpc.WithEndpoint("otel-collector:4317"),
    otlptracegrpc.WithInsecure(),
)
```

For services that cannot use gRPC (e.g., shell scripts), the HTTP/protobuf endpoint is available at `otel-collector:4318`.

---

## 8. Resource Estimation

### 8.1 Current volume (cc-connect only, 90 messages/day)

| Signal | Events/day | Event size | Daily volume | 90-day total |
|--------|-----------|-----------|-------------|--------------|
| Traces | ~540 spans | ~300 bytes | ~162 KB | ~14.6 MB |
| Metrics | ~90 datapoints | ~200 bytes | ~18 KB | ~1.6 MB |
| Logs | ~180 records | ~250 bytes | ~45 KB | ~4 MB |
| **Total** | **~810 events** | | **~225 KB** | **~20 MB** |

### 8.2 With all OTel services deployed

| Signal | Events/day | Daily volume | 90-day total |
|--------|-----------|-------------|--------------|
| Traces | ~2,000 | ~600 KB | ~54 MB |
| Metrics | ~1,000 | ~200 KB | ~18 MB |
| Logs | ~5,000 | ~1.25 MB | ~112 MB |
| **Total** | **~8,000** | **~2 MB** | **~184 MB** |

### 8.3 Infrastructure resource usage

| Component | CPU | Memory | Disk |
|-----------|-----|--------|------|
| OTel Collector | <0.1 core | ~128 MB | 0 (in-memory queue) |
| Vector | <0.1 core | ~256 MB | 0 (in-memory buffer) |
| ClickHouse (additional) | Negligible | Negligible | <200 MB / 90 days |

All estimates are well within the capabilities of the Mac/Orbstack host. No dedicated infra needed.

### 8.4 Network

- OTLP gRPC traffic from services to collector: <10 KB/day
- OTLP gRPC from collector to Vector: <10 KB/day  
- Vector to ClickHouse HTTP: <10 KB/day

Total observability network overhead: <30 KB/day internal. Negligible.

---

## 9. Grafana Integration

### 9.1 Data sources

| Data source | Tables | Purpose |
|-------------|--------|---------|
| ClickHouse (existing) | `kyb.otel_spans`, `kyb.otel_metrics`, `kyb.otel_logs` | Long-term trace, metric, and log queries |
| ClickHouse (existing) | `cc.message_log`, `kyb.claude_hook_events`, `infra.docker_events` | Legacy tables (continue existing dashboards) |

No new data sources needed. All data lands in ClickHouse.

### 9.2 Trace query examples

**Find trace by message ID:**
```sql
SELECT trace_id, span_name, span_kind, service_name, duration_nanos,
       cluster, environment
FROM kyb.otel_spans
WHERE feishu_msg_id = 'om_abc123'
ORDER BY timestamp;
```

**Slow traces in last 24h (P95 > 10s):**
```sql
SELECT trace_id, service_name,
       sum(duration_nanos) / 1e9 AS total_duration_sec,
       count() AS span_count
FROM kyb.otel_spans
WHERE timestamp >= now() - INTERVAL 1 DAY
GROUP BY trace_id, service_name
HAVING total_duration_sec > 10
ORDER BY total_duration_sec DESC
LIMIT 20;
```

**Error rate by service:**
```sql
SELECT service_name,
       countIf(status_code = 'Error') AS error_spans,
       count() AS total_spans,
       round(error_spans / total_spans * 100, 2) AS error_rate_pct
FROM kyb.otel_spans
WHERE timestamp >= now() - INTERVAL 1 DAY
GROUP BY service_name;
```

### 9.3 Metric query examples

**Messages received over time (from cc-connect metrics):**
```sql
SELECT toStartOfMinute(timestamp) AS ts,
       sum(metric_value) AS received
FROM kyb.otel_metrics
WHERE metric_name = 'cc.messages.received'
  AND timestamp >= now() - INTERVAL 1 DAY
GROUP BY ts
ORDER BY ts;
```

**P50 / P90 / P99 turn duration:**
```sql
SELECT toStartOfHour(timestamp) AS ts,
       quantile(0.50)(metric_value) AS p50,
       quantile(0.90)(metric_value) AS p90,
       quantile(0.99)(metric_value) AS p99
FROM kyb.otel_metrics
WHERE metric_name = 'cc.turn_duration_ms'
  AND timestamp >= now() - INTERVAL 7 DAY
GROUP BY ts
ORDER BY ts;
```

### 9.4 Log query example

**Recent errors:**
```sql
SELECT timestamp, service_name, severity_text, body, cluster
FROM kyb.otel_logs
WHERE severity_number >= 17  -- ERROR+
  AND timestamp >= now() - INTERVAL 1 HOUR
ORDER BY timestamp DESC
LIMIT 50;
```

### 9.5 Dashboard recommendations

New dashboards to create:

| Dashboard | Data source | Panels |
|-----------|-------------|--------|
| **OTel Traces** | `kyb.otel_spans` | Trace list (table), Error rate (time series), Slow traces (table), Span duration heatmap |
| **OTel Metrics** | `kyb.otel_metrics` | Top metrics (table), Per-metric time series, Latency histograms |
| **Observability Pipeline Health** | `kyb.otel_*` + Vector self-monitoring | Ingestion rate (events/min), Pipeline latency (ingested_at - timestamp), Error rate per service |

---

## 10. Migration from Existing Pipelines

### 10.1 What changes

| Existing pipeline | Change |
|-------------------|--------|
| cc-connect → Vector → `cc.message_log` | **No change** (continue as-is, or migrate cc-connect logging to OTel logs for unified pipeline) |
| cc-connect OTel → Collector → Tempo | **Replaced**: Collector now forwards to Vector instead of Tempo. Traces go to ClickHouse via Vector. |
| Claude hooks → emit-ck.sh → `kyb.claude_hook_events` | **No change** (hook pipeline is separate; Claude Code does not natively support OTLP) |
| Docker events → docker-event-watcher → `infra.docker_events` | **No change** (shell-based pipeline; Docker events can be forwarded to OTel in the future) |

### 10.2 Deprecation of Tempo-only path

The existing `otel-cc-connect.md` design sends traces from Collector to Tempo. This is replaced by the Collector -> Vector -> ClickHouse path. Tempo is no longer needed because:

- ClickHouse stores traces natively with equal query capability
- Grafana's ClickHouse data source supports the same trace filtering and exploration
- Eliminates a separate stateful service (Tempo requires persistent storage and its own retention policy)

If Tempo's trace waterfall UI is desired later, Vector can add a Tempo sink alongside ClickHouse, or ClickHouse can export traces to Tempo via the `clickhouse-grpc` connector.

### 10.3 Phased rollout

**Phase 1 (P0): Deploy Vector + ClickHouse schemas**
1. Create `kyb.otel_spans`, `kyb.otel_metrics`, `kyb.otel_logs` tables
2. Deploy Vector container with basic enrichment and ClickHouse sinks
3. Verify Vector starts and CK healthcheck passes
4. Deploy OTel Collector container
5. Verify Collector forwards test data to Vector

**Phase 2 (P0): connect cc-connect OTel**
1. Point cc-connect OTLP exporter from `tempo:4317` to `otel-collector:4317`
2. Verify traces appearing in `kyb.otel_spans`
3. Build Grafana trace dashboard

**Phase 3 (P1): enrich + route refinement**
1. Tune VRL enrichment rules for attribute normalization
2. Add route-based transforms for error/high-latency alerting
3. Add metric handling from cc-connect

**Phase 4 (P2): legacy pipeline convergence**
1. Migrate cc-connect structured logging from direct Vector file tail to OTel logs
2. Evaluate Docker event watcher replacement with OTel-aware Docker event exporter
3. Deprecate `cc.message_log` in favor of unified `kyb.otel_logs` (or keep both)

---

## 11. Self-Observability

The pipeline must be observable. Define health checks:

### 11.1 OTel Collector health

```bash
# Check collector is running
curl http://otel-collector:13133/health/status  200
# Check zpages (debug)
curl http://otel-collector:55679/debug/tracez
```

### 11.2 Vector health

```bash
# Vector GraphQL API
curl http://vector:8686/health
# Vector CLI within container
docker exec vector vector top
```

### 11.3 Data freshness alerts

Alert when no new spans in `kyb.otel_spans` for 5 minutes (cc-connect producing) or 30 minutes (idle period):

```sql
-- Alert query: no spans from cc-connect in last 15 minutes
SELECT count() AS recent_spans
FROM kyb.otel_spans
WHERE service_name = 'cc-connect'
  AND timestamp >= now() - INTERVAL 15 MINUTE;
```

If `recent_spans` is 0 and cc-connect is known to be active, either the pipeline is down or cc-connect itself is down.

### 11.4 Ingestion latency

```sql
SELECT avg(toUnixTimestamp(_ingested_at) - toUnixTimestamp(timestamp)) AS ingest_lag_sec
FROM kyb.otel_spans
WHERE timestamp >= now() - INTERVAL 5 MINUTE;
```

Expected: <5 seconds. Alert if >60 seconds.

---

## 12. Comparison with Alternatives

### Option A: OTel Collector direct to ClickHouse (no Vector)

```
OTel Collector → ClickHouse (via ClickHouse exporter or OTel HTTP)
```

**Pros**: Fewer moving parts (no Vector). Simpler deployment. Lower resource usage.

**Cons**: No VRL enrichment (OTel Collector transform processors are less expressive). No content-based routing. Adding new destinations requires changing Collector config (tight coupling). The Collector must know about CK schema.

**Verdict**: Suitable for cases where no enrichment or routing is needed. Not recommended for this project because enrichment (cluster, environment injection) and routing (signal-based table selection) are core requirements.

### Option B: Vector direct OTLP (no Collector)

```
App → Vector (opentelemetry source) → VRL → ClickHouse
```

**Pros**: Simpler topology. One less container to manage.

**Cons**: Vector must handle OTLP termination and enrichment in the same process. No protocol isolation. Restarting Vector (for config changes) also disrupts OTLP ingestion. The opentelemetry source and VRL transforms compete for resources.

**Verdict**: Workable at current scale. If operational overhead is the main concern, this is a pragmatic choice. The two-stage design is recommended primarily for backpressure isolation and future extensibility.

### Option C: Add Kafka (presented separately in kafka-message-bus.md)

```
App → Collector → Kafka → Vector → ClickHouse
```

**Pros**: Strong durability guarantees. Replay capability. Multiple consumers.

**Cons**: Significant operational complexity (Kafka cluster management, ZK/KRaft, topic configuration). At <1K events/day, Kafka is extreme overkill.

**Verdict**: Unnecessary at current scale. Add only if the project grows 100x or if replay becomes a hard requirement.

### Recommendation: Option A (chosen design) with Option B as fallback

The two-stage (Collector + Vector) architecture is the recommended design because it provides the best separation of concerns and extensibility. If operational overhead becomes a concern, collapsing to Option B is straightforward: replace `otel-collector:4317` with `vector:4317` and remove the Collector-to-Vector port mapping.

---

## 13. Verdict

**Design is ready for implementation.** The two-stage OTel Collector + Vector pipeline provides:

1. **Unified OTLP ingestion** -- One endpoint for all OTel-instrumented services
2. **Centralized enrichment** -- Cluster, environment, attribute normalization in Vector VRL
3. **Signal-based routing** -- Traces, metrics, logs to separate ClickHouse tables
4. **Backpressure isolation** -- Collector absorbs client backpressure; Vector absorbs CK backpressure
5. **Extensibility** -- New sinks (Kafka, Tempo, S3) require only Vector config changes
6. **Minimal resource footprint** -- <500 MB combined RAM, negligible storage

### Implementation priority

| Step | Action | Priority | Effort |
|------|--------|----------|--------|
| 1 | Create `kyb.otel_spans`, `kyb.otel_metrics`, `kyb.otel_logs` tables | P0 | 5 min |
| 2 | Deploy Vector container with enrichment and CK sinks | P0 | 15 min |
| 3 | Deploy OTel Collector container | P0 | 10 min |
| 4 | Point cc-connect OTel exporter to collector | P0 | 5 min |
| 5 | Verify traces in CK | P0 | 5 min |
| 6 | Build Grafana trace dashboard | P1 | 30 min |
| 7 | Add metric handling from cc-connect | P1 | 20 min |
| 8 | Add error/high-latency alert routes | P2 | 15 min |
| 9 | Migrate cc-connect log sourcing to OTel logs | P2 | 30 min |

### Key risks

1. **Vector `opentelemetry` source maturity** -- The `opentelemetry` source in Vector is relatively new (GA since Vector 0.38). Monitor for bugs in signal type detection or attribute serialization.

2. **Map type query ergonomics** -- ClickHouse `Map(String, String)` requires `mapContains` or `arrayExists` for filtering. Grafana variable queries over Map keys may need workarounds. Mitigation: extract high-value attributes to dedicated columns.

3. **VRL complexity at scale** -- VRL is powerful but has no testing framework. Complex transforms can silently drop events on runtime errors. Mitigation: separate transforms by concern (one VRL per transform block), test with `vector vtl` command.

4. **OTel Collector vs. Vector version compatibility** -- OTLP protocol version mismatch between Collector and Vector could cause deserialization errors. Mitigation: use the `otlp` gRPC exporter (not HTTP) and pin versions.

---

## 14. References

- OTel Collector: https://opentelemetry.io/docs/collector/
- Vector OTel source: https://vector.dev/docs/reference/configuration/sources/opentelemetry/
- Vector VRL: https://vector.dev/docs/reference/vrl/
- Vector ClickHouse sink: https://vector.dev/docs/reference/configuration/sinks/clickhouse/
- ClickHouse Map type: https://clickhouse.com/docs/en/sql-reference/data-types/map
- OTel semantic conventions: https://opentelemetry.io/docs/specs/semconv/

- Previous observability design: `docs/infra/observability-design.md`
- Existing bridge CK ingestion: `docs/infra/designs/bridge-ck-ingestion.md`
- cc-connect OTel design: `docs/infra/reviews/otel-cc-connect.md`
- Docker event monitoring: `docs/infra/reviews/docker-events.md`
- Kafka message bus proposal: `docs/infra/reviews/kafka-message-bus.md`
- Claude hooks pipeline: `docs/infra/handbook/hooks-ck-pipeline.md`

> ／人◕ ‿‿ ◕人＼
