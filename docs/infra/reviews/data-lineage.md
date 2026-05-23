---
decision: 稍后做
---

# Data Lineage Tracking for Observability Pipeline

**Date:** 2026-05-23
**Status:** Design proposal
**Prerequisite reading:** `docs/infra/observability-design.md` (observability stack overview),
`docs/infra/reviews/vector-pipeline.md` (Vector log shipping),
`docs/infra/reviews/otel-cc-connect.md` (OTel tracing for cc-connect),
`docs/infra/reviews/feishu-delivery.md` (Feishu delivery monitoring).

---

## 1. Problem

Currently, the observability pipeline has per-component monitoring but no **end-to-end data lineage** for individual messages. When a user sends a message in Feishu, the pipeline is:

```
Feishu ──► cc-connect ──► Vector ──► ClickHouse ──► Grafana
```

Each component logs its own view of events, but there is no common trace ID that connects a log line in cc-connect to the same event in Vector, to its row in ClickHouse, to a panel refresh in Grafana.

### 1.1 Gaps

| Gap | Impact |
|-----|--------|
| No trace ID propagation across hops | Cannot determine which hop dropped a message |
| No per-hop latency tracking | Cannot distinguish "Vector is slow to ingest" from "CK query is slow" from "Grafana panel is slow to render" |
| No end-to-end latency SLI | Cannot measure pipeline health from a user's perspective |
| Hop-level health is inferred, not measured | Each component health is a separate metric without correlation |
| Debugging requires manual log correlation across 4 systems | Incident response time is dominated by log spelunking |

### 1.2 Pipeline Hops

```
feishu    cc-connect    Vector        ClickHouse    Grafana
  │           │            │              │            │
  │   HOP 1   │    HOP 2   │    HOP 3     │   HOP 4    │
  │──────────►│───────────►│─────────────►│───────────►│
  │           │            │              │            │
  │   send    │  log emit  │  ingest      │  query     │
  │   e2e     │  (stdout)  │  (HTTP POST) │  (HTTP GET)│
  │   latency │            │              │            │
```

**Hops:**

| Hop | From | To | Mechanism | Latency Name |
|-----|------|----|-----------|--------------|
| 1 | Feishu WS | cc-connect | WebSocket event | `feishu_to_cc` |
| 2 | cc-connect stdout | Vector `docker_logs` source | Docker log stream | `cc_to_vector` |
| 3 | Vector sink | ClickHouse table | HTTP INSERT (batch) | `vector_to_ck` |
| 4 | ClickHouse table | Grafana panel | HTTP query (SQL) | `ck_to_grafana` |

---

## 2. Design Overview

### 2.1 Principle: Universal Trace ID

Every message receives a single `trace_id` (UUID v7, time-sortable) at the point of entry (cc-connect receives from Feishu WebSocket). This trace ID propagates through the entire pipeline:

- **cc-connect:** Included in every structured log line (slog key=value).
- **Vector:** Extracted from log lines, used as ClickHouse sorting key.
- **ClickHouse:** Stored as a column, indexed for fast lookup.
- **Grafana:** Exposed in panel tooltips and explore queries for trace-to-dashboard correlation.

### 2.2 Architecture

```
                           trace_id injected here
                                  │
                                  ▼
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Feishu  │───►│cc-connect│───►│  Vector  │───►│ClickHouse│───►│  Grafana │
│    WS    │    │ (Go slog)│    │(docker   │    │(MergeTree│    │(Dashboard│
│          │    │trace_id  │    │ logs src)│    │  tables) │    │  panels) │
│          │    │in every  │    │ extract  │    │ trace_id │    │ latency  │
│          │    │log line  │    │ trace_id │    │  indexed │    │ per panel│
└──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
                     │               │               │               │
                     ▼               ▼               ▼               ▼
              ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
              │ Hop 1 metric │ │ Hop 2 metric │ │ Hop 3 metric │ │ Hop 4 metric │
              │ event_receive│ │ log_emit     │ │ insert_latency│ │ query_latency│
              │ → log_write │ │ → vector_rcv │ │ → ck_ack     │ │ → panel_render│
              └──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘

                               All metrics tagged with trace_id
```

### 2.3 Trace Flow

```
msg_id=om_xxx → trace_id = uuid_v7("om_xxx")

cc-connect (msg received):
  trace_id=abc123 msg_id=om_xxx event_type=message_received  ← log line 1
  
cc-connect (turn complete):
  trace_id=abc123 msg_id=om_xxx event_type=message_sent      ← log line 2

Vector:
  trace_id=abc123 ingested_at=now()  ← enriches log line, adds ingestion timestamp

ClickHouse:
  cc.message_log row with trace_id=abc123, event_time, ingested_at, ...

Grafana:
  Dashboard queries WHERE trace_id=abc123
  → Computes latency: ingested_at - event_time = hop2+hop3 latency
  → Measures query_time_ms = panel render duration
```

---

## 3. Trace ID Injection

### 3.1 Trace ID Format

```go
// UUID v7 (time-sortable, ms-precision prefix) from cc-connect's existing msg_id.
// The msg_id from Feishu (om_xxxxxxxxxx) is already unique and time-prefixed.
// Use it directly as the trace_id to avoid generating a new ID.
trace_id = msg_id  // "om_<timestamp><random>"
```

**Rationale:** Feishu `msg_id` is already unique, time-ordered, and available at the entry point. Using it as `trace_id` eliminates a mapping step. If a message does not have an `msg_id` (e.g., heartbeats), generate a UUID v7 at the log emission point.

### 3.2 cc-connect Instrumentation

cc-connect already logs structured key=value lines via Go `slog`. The delta is adding `trace_id` to every log line:

```go
// Current log line:
slog.Info("message received",
    "msg_id", event.MessageID,
    "platform", "feishu",
    "session", session,
    "user", userID,
    "content_len", len(content),
)

// With trace_id added:
slog.Info("message received",
    "trace_id", event.MessageID,  // trace_id = msg_id
    "msg_id", event.MessageID,
    "platform", "feishu",
    "session", session,
    "user", userID,
    "content_len", len(content),
)
```

**Log lines that MUST carry trace_id:**

| Log Line | Fields Added | Purpose |
|----------|-------------|---------|
| `message received` | `trace_id` | Entry point — establishes trace |
| `turn complete` | `trace_id`, `turn_duration` | Pipeline completion marker |
| `permission request` | `trace_id`, `request_id` | Sub-trace for permission flow |
| `permission resolved` | `trace_id`, `request_id` | Permission completion |
| `slow agent send` | `trace_id`, `elapsed` | Degradation signal |

### 3.3 Vector Extract Transform

Vector's VRL remap transform extracts `trace_id` from the cc-connect log line and promotes it to a top-level event field:

```coffee
[transforms.extract_trace_id]
type = "remap"
inputs = ["parse_cc_kv"]
source = '''
  # Promote trace_id from parsed fields
  if exists(.trace_id) {
    .trace_id = del(.trace_id)
  } else if exists(.msg_id) {
    # Fallback: use msg_id as trace_id if trace_id not present
    .trace_id = .msg_id
  } else {
    # Last resort: generate a UUID
    .trace_id = uuid_v7()
  }
'''
```

### 3.4 ClickHouse Schema

The `cc.message_log` table (already defined in `vector-pipeline.md`) gets a `trace_id` column and index:

```sql
CREATE TABLE cc.message_log (
    -- Identifiers (trace_id is primary lineage key)
    trace_id        String,              -- msg_id or UUID v7
    msg_id          String,

    -- Timestamps
    event_time      DateTime64(3),       -- when cc-connect logged the event
    ingested_at     DateTime64(3),       -- when Vector inserted to CK
    -- ... other fields as defined in vector-pipeline.md ...

) ENGINE = MergeTree
ORDER BY (event_time, trace_id)          -- trace_id in sort key for fast lookup
TTL event_time + INTERVAL 90 DAY
```

**Indexes:**
```sql
-- Primary lookup by trace_id
ALTER TABLE cc.message_log ADD INDEX idx_trace_id trace_id TYPE bloom_filter(0.01) GRANULARITY 1;

-- Lookup by trace_id + event_type (find both inbound and outbound for same trace)
ALTER TABLE cc.message_log ADD INDEX idx_trace_event (trace_id, event_type) TYPE set(100) GRANULARITY 2;
```

---

## 4. Per-Hop Latency Model

### 4.1 Latency Definitions

```
Timeline:
                                                                     Grafana
feishu    cc-connect         Vector            ClickHouse           panel
  |           |                 |                  |                  |
  |--t0-------|                 |                  |                  |
  |           |--t1-------------|                  |                  |
  |           |                 |--t2--------------|                  |
  |           |                 |                  |--t3--------------|
  |           |                 |                  |                  |
  |<--- hop1 -->|<--- hop2 ---->|<---- hop3 ------>|<--- hop4 ------->|
  |                                                                   |
  |<------------------------- end-to-end latency --------------------->|
```

| Hop | Latency | t_start | t_end | Source |
|-----|---------|---------|-------|--------|
| 1 | `feishu_to_cc` | Feishu event timestamp (`event_time` from Feishu WebSocket payload) | cc-connect `slog.Info` call | Calculated: `event_time` (log) - `feishu_event.ts` |
| 2 | `cc_to_vector` | cc-connect `slog.Info` call (`event_time` in log line) | Vector picks up line from Docker log stream | Calculated: `vector_received_at` - `event_time` |
| 3 | `vector_to_ck` | Vector HTTP INSERT start | ClickHouse ack (insert committed) | Calculated: `ingested_at` - `vector_received_at` |
| 4 | `ck_to_grafana` | Grafana sends SQL query | Grafana renders panel | Measured: Grafana `query_time_ms` panel option, or `request_time_ms` in browser devtools |

**Note:** Hop 1 and Hop 4 are shaped by external factors (network latency to Feishu, browser performance). Hops 2 and 3 are within the local observability stack and are the primary targets for optimization and alerting.

### 4.2 Timestamp Sources

| Timestamp | Source | Precision | Reliability |
|-----------|--------|-----------|-------------|
| `feishu_event.ts` | Feishu WebSocket event payload | Second | High (Feishu server time) |
| `event_time` | cc-connect `time=` field in log line | Millisecond (Go `time.Now`) | High (local clock) |
| `vector_received_at` | Vector ingestion metadata | Millisecond (Vector `now()`) | High (Vector clock) |
| `ingested_at` | ClickHouse `DEFAULT now64()` | Millisecond (CK server clock) | High (CK clock) |
| `grafana_query_start` | Grafana panel query timing | Millisecond (browser/grafana) | Medium (can vary with browser) |

**Clock drift concern:** All hops run on the same Mac/Orbstack host (or within the same Docker network). Clock drift between containers is negligible (<1ms). For multi-cluster setups (Aliyun, Office), clocks are NTP-synced.

### 4.3 Storage in ClickHouse

A dedicated lineage metrics table captures per-hop latency observations:

```sql
CREATE TABLE infra.lineage_metrics (
    -- Time
    timestamp       DateTime64(3),

    -- Trace identity
    trace_id        String,
    msg_id          String,

    -- Hop timestamps (raw)
    ts_feishu       DateTime64(3),        -- from Feishu event (if available)
    ts_cc_connect   DateTime64(3),        -- event_time from log line
    ts_vector_rcv   DateTime64(3),        -- when Vector received the event
    ts_ck_insert    DateTime64(3),        -- ingested_at when CK committed
    ts_grafana_qry  DateTime64(3),        -- when Grafana initiated the query
    ts_grafana_rndr DateTime64(3),        -- when Grafana finished rendering

    -- Hop latencies (pre-computed seconds, Float64 for sub-ms)
    latency_feishu_to_cc    Float32,      -- hop 1
    latency_cc_to_vector    Float32,      -- hop 2
    latency_vector_to_ck    Float32,      -- hop 3
    latency_ck_to_grafana   Float32,      -- hop 4
    latency_e2e             Float32,      -- total

    -- Hop health flags (1=healthy, 0=degraded)
    hop1_healthy    UInt8 DEFAULT 1,
    hop2_healthy    UInt8 DEFAULT 1,
    hop3_healthy    UInt8 DEFAULT 1,
    hop4_healthy    UInt8 DEFAULT 1,

    -- Metadata
    event_type      LowCardinality(String),
    cluster         LowCardinality(String),
    container_name  String
) ENGINE = MergeTree
ORDER BY (timestamp, trace_id)
TTL timestamp + INTERVAL 30 DAY
```

**Materialized view for aggregation:**

```sql
CREATE MATERIALIZED VIEW infra.lineage_latency_hourly_mv
ENGINE = AggregatingMergeTree()
ORDER BY (toStartOfHour(timestamp), hop_name)
AS
SELECT
    toStartOfHour(timestamp) AS hour,
    'hop1_feishu_to_cc' AS hop_name,
    avg(latency_feishu_to_cc) AS latency_avg,
    quantile(0.50)(latency_feishu_to_cc) AS latency_p50,
    quantile(0.90)(latency_feishu_to_cc) AS latency_p90,
    quantile(0.99)(latency_feishu_to_cc) AS latency_p99,
    min(latency_feishu_to_cc) AS latency_min,
    max(latency_feishu_to_cc) AS latency_max,
    count() AS sample_count,
    sum(hop1_healthy) AS healthy_count,
    1 - (sum(hop1_healthy) / count()) AS degradation_ratio
FROM infra.lineage_metrics
GROUP BY hour, hop_name

UNION ALL

-- Same aggregation for hop2, hop3, hop4, e2e
-- (elided for brevity — same pattern with different latency column)
SELECT
    toStartOfHour(timestamp) AS hour,
    'hop2_cc_to_vector' AS hop_name,
    avg(latency_cc_to_vector),
    quantile(0.50)(latency_cc_to_vector),
    quantile(0.90)(latency_cc_to_vector),
    quantile(0.99)(latency_cc_to_vector),
    min(latency_cc_to_vector),
    max(latency_cc_to_vector),
    count(),
    sum(hop2_healthy),
    1 - (sum(hop2_healthy) / count())
FROM infra.lineage_metrics
GROUP BY hour, hop_name

UNION ALL

SELECT
    toStartOfHour(timestamp) AS hour,
    'hop3_vector_to_ck' AS hop_name,
    avg(latency_vector_to_ck),
    quantile(0.50)(latency_vector_to_ck),
    quantile(0.90)(latency_vector_to_ck),
    quantile(0.99)(latency_vector_to_ck),
    min(latency_vector_to_ck),
    max(latency_vector_to_ck),
    count(),
    sum(hop3_healthy),
    1 - (sum(hop3_healthy) / count())
FROM infra.lineage_metrics
GROUP BY hour, hop_name

UNION ALL

SELECT
    toStartOfHour(timestamp) AS hour,
    'hop4_ck_to_grafana' AS hop_name,
    avg(latency_ck_to_grafana),
    quantile(0.50)(latency_ck_to_grafana),
    quantile(0.90)(latency_ck_to_grafana),
    quantile(0.99)(latency_ck_to_grafana),
    min(latency_ck_to_grafana),
    max(latency_ck_to_grafana),
    count(),
    sum(hop4_healthy),
    1 - (sum(hop4_healthy) / count())
FROM infra.lineage_metrics
GROUP BY hour, hop_name

UNION ALL

SELECT
    toStartOfHour(timestamp) AS hour,
    'e2e' AS hop_name,
    avg(latency_e2e),
    quantile(0.50)(latency_e2e),
    quantile(0.90)(latency_e2e),
    quantile(0.99)(latency_e2e),
    min(latency_e2e),
    max(latency_e2e),
    count(),
    -- e2e is healthy if all 4 hops are healthy
    sum(hop1_healthy AND hop2_healthy AND hop3_healthy AND hop4_healthy),
    1 - (sum(hop1_healthy AND hop2_healthy AND hop3_healthy AND hop4_healthy) / count())
FROM infra.lineage_metrics
GROUP BY hour, hop_name;
```

### 4.4 Latency Health Thresholds

| Hop | Healthy Target | Degraded | Critical | Typical Value (P50) |
|-----|---------------|----------|----------|---------------------|
| 1 — feishu_to_cc | < 500ms | 500ms–2s | > 2s | ~100ms |
| 2 — cc_to_vector | < 200ms | 200ms–1s | > 1s | ~50ms |
| 3 — vector_to_ck | < 1s | 1s–5s | > 5s | ~200ms (batched) |
| 4 — ck_to_grafana | < 200ms | 200ms–1s | > 1s | ~50ms |
| e2e | < 2s | 2s–10s | > 10s | ~400ms |

**Note:** Hop 3 appears high because Vector batches inserts (default 5s batch timeout). A single message waits up to 5s to be flushed. This is by design — batch inserts are more efficient. The health threshold should account for the configured `batch.timeout_secs`.

---

## 5. Vector Transforms for Lineage

### 5.1 Trace ID Extraction and Latency Computation

The Vector transform pipeline from `vector-pipeline.md` is extended with a new transform stage that computes per-hop latency:

```toml
# Step: Compute hop latency from cc-connect event_time
# Input: events already parsed by parse_cc_kv (has event_time, trace_id, etc.)
[transforms.compute_vector_hop_latency]
type = "remap"
inputs = ["extract_trace_id"]   # runs after trace_id is promoted
source = '''
  # vector_received_at = now() (when Vector received the event from Docker socket)
  .ts_vector_rcv = now()

  # Parse event_time (from cc-connect log line) for comparison
  .ts_cc_connect = parse_timestamp!(.event_time, format: "%+") ?? now()

  # Compute hop 2 latency: cc-connect log emit → Vector receives
  .latency_cc_to_vector = to_float!(.ts_vector_rcv - .ts_cc_connect) / 1_000_000_000.0

  # Flag health for hop 2
  if .latency_cc_to_vector > 1.0 {
    .hop2_healthy = 0
  } else if .latency_cc_to_vector > 0.2 {
    .hop2_healthy = 0
  } else {
    .hop2_healthy = 1
  }
'''

# Step: On CK sink completion, record insert latency
# This is handled by the legacy_client_side metric — Vector doesn't have
# an "after insert" hook in its transform layer.
# Instead, we compute hop 3 in ClickHouse after ingestion:
#   latency_vector_to_ck = ingested_at - ts_vector_rcv
```

### 5.2 Lineage Metrics Sink

A dedicated ClickHouse sink writes the `infra.lineage_metrics` table:

```toml
[sinks.clickhouse_lineage_metrics]
type = "clickhouse"
inputs = ["compute_vector_hop_latency"]
endpoint = "http://host.orb.internal:8123"
database = "infra"
table = "lineage_metrics"
encoding.timestamp_format = "unix"
batch.timeout_secs = 5
batch.max_events = 500
healthcheck.enabled = false

[sinks.clickhouse_lineage_metrics.inputs]
type = "filter"
condition = 'exists(.trace_id) && (exists(.latency_cc_to_vector) || exists(.ts_cc_connect))'
```

### 5.3 Vector Component Diagram (Extended)

```
docker_infra (source)
    │
    ▼
filter_cc_connect (filter)
    │
    ▼
parse_cc_kv (remap)              ← parses slog key=value
    │
    ▼
extract_trace_id (remap)          ← NEW: promotes trace_id from msg_id
    │
    ▼
compute_vector_hop_latency (remap) ← NEW: adds ts_vector_rcv, latency_cc_to_vector
    │
    ├──────────────────────────────┐
    ▼                              ▼
add_cluster_metadata            clickhouse_lineage_metrics (sink)
    │                                    NEW: infra.lineage_metrics
    ▼
reduce_cc_msg / join_cc_msg
    │
    ▼
clickhouse_cc_messages (sink)   ← existing: cc.message_log
```

---

## 6. ClickHouse Computed Latency

### 6.1 Hop 3: Vector to ClickHouse

Since Vector's transform layer cannot measure post-insert latency, hop 3 is computed in ClickHouse as a background materialization:

```sql
-- Backfill latency_vector_to_ck for rows where it's NULL
ALTER TABLE infra.lineage_metrics
    UPDATE latency_vector_to_ck = dateDiff('millisecond', ts_vector_rcv, ts_ck_insert) / 1000.0
    WHERE latency_vector_to_ck IS NULL AND ts_vector_rcv IS NOT NULL;
```

This runs as a periodic job (every 5 minutes via cron or ClickHouse `ON CLUSTER` scheduled query):

```sql
-- Compute from cc.message_log: ingested_at - event_time ≈ vector_to_ck (rough)
-- More precise: compare log line's event_time with ingested_at from Vector
SELECT
    trace_id,
    event_time AS ts_cc_connect,
    ingested_at AS ts_ck_insert,
    dateDiff('millisecond', event_time, ingested_at) / 1000.0 AS latency_vector_to_ck
FROM cc.message_log
WHERE ingested_at > now() - INTERVAL 10 MINUTE
  AND event_type IN ('message_received', 'message_sent')
ORDER BY latency_vector_to_ck DESC
LIMIT 10;
```

### 6.2 Hop 4: ClickHouse to Grafana

Hop 4 latency is measured at the Grafana layer and written back to ClickHouse via a Grafana panel or a separate reporting endpoint.

**Option A: Grafana panel using query timing (recommended)**

Each Grafana panel that sources from ClickHouse emits a `query_time_ms` metric as a panel annotation or writes to a custom table via Grafana's HTTP sink. The simplest approach is a Grafana **annotation** that records panel render time:

```sql
-- Query for Grafana dashboard: Pipeline Latency Dashboard
-- Each panel adds a comment with its render duration

-- Panel: Hop 4 Latency
SELECT
    $__timeFilter(timestamp),
    latency_ck_to_grafana
FROM infra.lineage_metrics
WHERE $__timeFilter(timestamp)
ORDER BY timestamp DESC;
```

The panel itself reveals hop 4 latency: the time from the latest `ts_ck_insert` to the moment the panel query returns is an approximation of hop 4.

**Option B: Grafana API reporting**

A small cron script runs every minute, queries the Grafana API for dashboard panel render times (the `grafana-dashboard` API returns `executionTime` in query results), and inserts the max/avg into `infra.lineage_metrics`:

```bash
# Collect Grafana panel render times and report to CK
# Run every minute via cron
for panel_id in "pipeline-e2e-latency" "pipeline-hop-breakdown"; do
  render_time_ms=$(curl -s -H "Authorization: Bearer $GRAFANA_TOKEN" \
    "http://grafana:3000/api/dashboards/uid/$DASHBOARD_UID" \
    | jq '.dashboard.panels[] | select(.id == $panel_id) | .renderTime' 2>/dev/null)

  if [ -n "$render_time_ms" ]; then
    clickhouse-client --host host.orb.internal \
      --query "INSERT INTO infra.lineage_metrics (timestamp, trace_id, latency_ck_to_grafana, hop4_healthy)
               VALUES (now(), 'grafana_poll_$(date +%s)', $render_time_ms / 1000.0,
                       IF($render_time_ms < 1000, 1, 0))"
  fi
done
```

**Recommendation:** Use Option A for real-time visibility (panel shows its own latency), Option B for historical tracking (store per-minute render times).

---

## 7. Grafana Dashboard: Pipeline Lineage

### 7.1 Dashboard: "Observability Pipeline Health"

**Panel 1: End-to-End Latency (Singlestat + Sparkline)**

```
Query: SELECT latency_e2e FROM infra.lineage_metrics ORDER BY timestamp DESC LIMIT 1
Format: current value + 1-hour sparkline
Thresholds:
  green:  < 2s
  yellow: 2s–10s
  red:    > 10s
```

**Panel 2: Per-Hop Latency Breakdown (Bar Chart)**

```
Query: SELECT
         toStartOfMinute(timestamp) AS t,
         avg(latency_feishu_to_cc) AS hop1,
         avg(latency_cc_to_vector) AS hop2,
         avg(latency_vector_to_ck) AS hop3,
         avg(latency_ck_to_grafana) AS hop4
       FROM infra.lineage_metrics
       WHERE timestamp > now() - INTERVAL 1 HOUR
       GROUP BY t
       ORDER BY t

Type: Stacked bar chart (each hop is a color)
Unit: seconds
Legend: Show hop name and P50/P90 labels
```

**Panel 3: Hop Latency Heatmap (per hop, 4 rows)**

```
Type: 4 horizontal heatmaps (one per hop)
Query per hop:
  SELECT
    toStartOfFiveMinutes(timestamp) AS t,
    toUInt64(latency_* / 0.05) * 0.05 AS bucket,
    count() AS count
  FROM infra.lineage_metrics
  WHERE timestamp > now() - INTERVAL 6 HOUR
  GROUP BY t, bucket

Color: Green (fast) → Yellow → Red (slow)
Y-axis: time buckets
X-axis: 5-minute windows
```

**Panel 4: Pipeline Health Score (Gauge)**

```
Query: SELECT
         sum(hop1_healthy) / count() AS hop1_score,
         sum(hop2_healthy) / count() AS hop2_score,
         sum(hop3_healthy) / count() AS hop3_score,
         sum(hop4_healthy) / count() AS hop4_score
       FROM infra.lineage_metrics
       WHERE timestamp > now() - INTERVAL 5 MINUTE

Display: 4 gauges (0-100%), threshold at 99% for degradation
```

**Panel 5: Trace Explorer (Table)**

```
Query: SELECT
         timestamp,
         trace_id,
         msg_id,
         latency_feishu_to_cc,
         latency_cc_to_vector,
         latency_vector_to_ck,
         latency_ck_to_grafana,
         latency_e2e,
         event_type
       FROM infra.lineage_metrics
       WHERE timestamp > now() - INTERVAL 1 HOUR
       ORDER BY timestamp DESC
       LIMIT 100

Actions: Click trace_id → drill-down to cc.message_log for that trace
```

**Panel 6: Degradation Event Log (Table)**

```
Query: SELECT
         timestamp,
         trace_id,
         format('Hop {} degraded: {:.2f}s (threshold: {:.1f}s)',
                IF(latency_feishu_to_cc > 2, 1,
                   IF(latency_cc_to_vector > 1, 2,
                      IF(latency_vector_to_ck > 5, 3, 4))),
                greatest(latency_feishu_to_cc, latency_cc_to_vector,
                         latency_vector_to_ck, latency_ck_to_grafana),
                CASE
                  WHEN latency_feishu_to_cc > 2 THEN 2.0
                  WHEN latency_cc_to_vector > 1 THEN 1.0
                  WHEN latency_vector_to_ck > 5 THEN 5.0
                  WHEN latency_ck_to_grafana > 1 THEN 1.0
                END) AS description
       FROM infra.lineage_metrics
       WHERE timestamp > now() - INTERVAL 1 HOUR
         AND (hop1_healthy = 0 OR hop2_healthy = 0 OR hop3_healthy = 0 OR hop4_healthy = 0)
       ORDER BY timestamp DESC
       LIMIT 50
```

### 7.2 Example Trace Drill-Down

When operator sees a slow trace:

```
trace_id = "om_abc123def456"

Step 1: Check per-hop latency
  SELECT * FROM infra.lineage_metrics WHERE trace_id = 'om_abc123def456'

  Result:
    latency_feishu_to_cc = 0.15       (fast)
    latency_cc_to_vector = 0.08       (fast)
    latency_vector_to_ck = 8.32       (SLOW — 8 seconds)
    latency_ck_to_grafana = 0.03      (fast)

  Conclusion: Vector → ClickHouse is the bottleneck.

Step 2: Check Vector health
  docker logs kyb-infra-vector --tail 20
  curl -s http://localhost:8686/metrics | grep clickhouse

  Look for: batch_timeouts, connection errors, CK endpoint unreachable.

Step 3: Check CK insert performance
  clickhouse-client --query "
    SELECT write_profile_event('InsertQuery') AS inserts_per_sec
  "
```

---

## 8. Instrumentation Points

### 8.1 Summary Table

| Point | Component | What to Add | How |
|-------|-----------|-------------|-----|
| P1 | cc-connect Go code | `trace_id` in all slog log lines | Add `"trace_id", event.MessageID` to every `slog.Info` call |
| P2 | Vector VRL transform | Extract `trace_id`, compute `ts_vector_rcv`, `latency_cc_to_vector` | New `extract_trace_id` and `compute_vector_hop_latency` remap transforms |
| P3 | Vector sink | Route to `infra.lineage_metrics` table | New `clickhouse_lineage_metrics` sink |
| P4 | ClickHouse | Compute `latency_vector_to_ck` post-insert | Periodic UPDATE or cron job |
| P5 | Grafana | Dashboard panels with per-query latency | Panel-level query timing annotations |
| P6 | Cron script (optional) | Poll Grafana API for render times | Shell script writing to `infra.lineage_metrics` |
| P7 | Vector | Auto-discover cc-connect container via Docker label | Already done in `vector-pipeline.md` (`kyb.service=cc-connect`) |
| P8 | All | Deploy Vector config update with new transforms | `docker exec kyb-infra-vector vector validate` + `SIGHUP` |

### 8.2 cc-connect Implementation Detail

The minimal change to cc-connect is adding `trace_id` to the slog attributes passed to every log call. Since cc-connect already passes `msg_id` to most log lines, this is a mechanical change:

```go
// Before:
slog.Info("message received",
    slog.String("msg_id", msgID),
    // ...
)

// After:
slog.Info("message received",
    slog.String("trace_id", msgID),  // trace_id = msg_id
    slog.String("msg_id", msgID),
    // ...
)
```

For log lines that do not have an `msg_id` (e.g., startup logs, config errors), omit `trace_id`. Vector will generate a fallback trace_id from the log line's container metadata.

### 8.3 Vector Config Extension

Add to existing `vector.toml` (from `vector-pipeline.md`):

```toml
# NEW: Extract trace_id from cc-connect parsed fields
[transforms.extract_trace_id]
type = "remap"
inputs = ["parse_cc_kv"]
source = '''
  # Promote trace_id from parsed fields
  if exists(.trace_id) {
    .trace_id = del(.trace_id)
  } else if exists(.msg_id) {
    .trace_id = .msg_id
  } else {
    .trace_id = uuid_v7()
  }
'''

# NEW: Compute Vector-side hop latency
[transforms.compute_vector_hop_latency]
type = "remap"
inputs = ["extract_trace_id"]
source = '''
  .ts_vector_rcv = now()

  if exists(.event_time) {
    parsed_ts = parse_timestamp!(.event_time, format: "%+") ?? now()
    .ts_cc_connect = parsed_ts
    .latency_cc_to_vector = to_float!(.ts_vector_rcv - .ts_cc_connect) / 1_000_000_000.0
    .hop2_healthy = if(.latency_cc_to_vector > 1.0, 0,
                      if(.latency_cc_to_vector > 0.2, 0, 1))
  }

  .hop1_healthy = 1   # default — hop 1 is before Vector's scope
  .hop3_healthy = 1   # default — hop 3 is computed post-insert in CK
  .hop4_healthy = 1   # default — hop 4 is computed at Grafana query time
'''

# NEW: Sink for lineage metrics
[sinks.clickhouse_lineage_metrics]
type = "clickhouse"
inputs = ["compute_vector_hop_latency"]
endpoint = "http://host.orb.internal:8123"
database = "infra"
table = "lineage_metrics"
encoding.timestamp_format = "unix"
batch.timeout_secs = 5
batch.max_events = 500
healthcheck.enabled = false
buffer.type = "memory"
buffer.max_events = 5000
buffer.when_full = "drop_newest"

# Filter: only cc-connect events with trace_id
[sinks.clickhouse_lineage_metrics.inputs]
type = "filter"
condition = '''
  exists(.trace_id) &&
  (.latency_cc_to_vector != null || .ts_cc_connect != null)
'''
```

### 8.4 Grafana Panel Implementation

Each panel in the Pipeline Lineage dashboard adds a `query_time_ms` annotation. The simplest approach is to version the panels with a `description` field that includes the render time:

```json
{
  "panels": [
    {
      "id": 1,
      "title": "End-to-End Latency",
      "type": "stat",
      "datasource": "ClickHouse",
      "targets": [
        {
          "query": "SELECT latency_e2e FROM infra.lineage_metrics ORDER BY timestamp DESC LIMIT 1",
          "format": "table"
        }
      ],
      "description": "Hop latencies computed from trace_id propagation. Panel render time appended as hop4 sample.",
      "fieldConfig": {
        "defaults": {
          "unit": "s",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green", "value": 0},
              {"color": "yellow", "value": 2},
              {"color": "red", "value": 10}
            ]
          }
        }
      }
    }
  ]
}
```

**Write-back via Grafana WebHook (advanced):**

Grafana 11+ supports `onPanelRender` event hooks that fire after a panel renders. A WebHook receiver could capture the render duration and POST to a lightweight HTTP endpoint that writes to ClickHouse:

```
Grafana Panel Render
    │
    ▼
WebHook POST → lightweight HTTP server (or Vector HTTP source)
    │
    ▼
infra.lineage_metrics (row: hop4 latency recorded)
```

This is optional and should be implemented only after the core pipeline (Hops 1-3) is stable.

---

## 9. Alerting

### 9.1 Alert Rules

| Rule | Condition | Severity | Cooldown | Action |
|------|-----------|----------|----------|--------|
| **Hop 2 degraded** | P50 latency_cc_to_vector > 200ms for 5 minutes | P3 | 15min | Check Vector CPU, Docker socket health |
| **Hop 3 degraded** | P50 latency_vector_to_ck > 5s for 5 minutes | P2 | 10min | Check CK connectivity, Vector buffer status |
| **Hop 3 failed** | latency_vector_to_ck > 30s OR no inserts for 5 minutes | P1 | 5min | Alert — data loss imminent |
| **Trace stalled** | message_received without matching message_sent for same trace_id within 10 minutes | P2 | 15min | Alert — message processing failure |
| **E2E degraded** | P50 latency_e2e > 10s for 5 minutes | P2 | 10min | Check all hops |
| **No lineage data** | No rows in infra.lineage_metrics for 5 minutes while cc.message_log has new rows | P1 | 5min | Alert — lineage pipeline broken |

### 9.2 Alert Queries

```sql
-- Hop 2 degraded (P3)
SELECT
    toStartOfMinute(timestamp) AS minute,
    avg(latency_cc_to_vector) AS avg_latency,
    count() AS samples
FROM infra.lineage_metrics
WHERE timestamp > now() - INTERVAL 5 MINUTE
GROUP BY minute
HAVING avg_latency > 0.2
ORDER BY minute DESC;

-- Trace stalled (inbound but no outbound within 10 minutes) (P2)
SELECT
    a.trace_id,
    a.timestamp AS received_at,
    dateDiff('minute', a.timestamp, now()) AS stalled_minutes
FROM infra.lineage_metrics AS a
LEFT JOIN infra.lineage_metrics AS b
    ON a.trace_id = b.trace_id AND b.event_type = 'message_sent'
WHERE a.event_type = 'message_received'
  AND b.trace_id IS NULL
  AND a.timestamp < now() - INTERVAL 10 MINUTE
ORDER BY stalled_minutes DESC;

-- No lineage data while messages exist (P1)
SELECT
    count() AS msg_count
FROM cc.message_log
WHERE ingested_at > now() - INTERVAL 5 MINUTE;

-- Run above, then:
SELECT
    count() AS lineage_count
FROM infra.lineage_metrics
WHERE timestamp > now() - INTERVAL 5 MINUTE;

-- If msg_count > 0 AND lineage_count == 0 → alert
```

### 9.3 Auto-Remediation

| Degradation | Auto-Action |
|-------------|-------------|
| Hop 2 (cc→Vector slow) | Restart Vector container (docker restart kyb-infra-vector) |
| Hop 3 (Vector→CK slow) | Retry connection, flush Vector buffer |
| Hop 4 (CK→Grafana slow) | Check Grafana datasource health, reconnect CK datasource |
| No lineage data | Restart Vector, verify extract_trace_id transform is enabled |

---

## 10. Implementation Roadmap

### Phase 1: Foundation (Day 1)

- [ ] Add `trace_id` to cc-connect slog log lines (all existing `slog.Info` calls with `msg_id`)
- [ ] Add `extract_trace_id` and `compute_vector_hop_latency` transforms to Vector config
- [ ] Create `infra.lineage_metrics` ClickHouse table
- [ ] Add `clickhouse_lineage_metrics` sink to Vector config
- [ ] Deploy Vector config update (validate + SIGHUP)
- [ ] Verify `trace_id` appears in Vector-enriched events

### Phase 2: Hop Latency Computation (Day 2)

- [ ] Verify hop 2 latency (`latency_cc_to_vector`) is being recorded
- [ ] Implement hop 3 backfill (cron or scheduled CK query for `latency_vector_to_ck`)
- [ ] Validate hop 1 timestamp extraction from Feishu event payload (if available)
- [ ] Add hop health flags based on threshold SLOs

### Phase 3: Grafana Dashboards (Day 3)

- [ ] Create "Observability Pipeline Health" dashboard
- [ ] Add E2E latency panel (Singlestat + sparkline)
- [ ] Add per-hop latency breakdown panel (stacked bar)
- [ ] Add hop latency heatmap panel
- [ ] Add pipeline health score gauges
- [ ] Add trace explorer table with drill-down

### Phase 4: Alerting (Day 4)

- [ ] Create alert rules in Grafana/Mimir for hop degradation
- [ ] Create "trace stalled" alert for messages stuck in pipeline
- [ ] Create "no lineage data" alert for pipeline health
- [ ] Wire P1 alerts to Feishu notification (via existing feishu-bridge)
- [ ] Test alert firing with simulated degradation

### Phase 5: Multi-Cluster (Week 2)

- [ ] Ensure `cluster` tag is propagated in `infra.lineage_metrics`
- [ ] Add cluster-level breakdown to Grafana dashboard
- [ ] Verify hop latency tracking works from Aliyun and Office clusters

---

## 11. Operational Considerations

### 11.1 Storage Cost

| Table | Rows/Day | Row Size | Daily Storage | 30-Day Retention |
|-------|----------|----------|---------------|------------------|
| `cc.message_log` | ~180 rows (90 msg × 2 log lines) | ~300 bytes | ~54 KB | ~1.6 MB |
| `infra.lineage_metrics` | ~180 rows | ~200 bytes | ~36 KB | ~1.1 MB |
| `infra.lineage_latency_hourly_mv` | 20 rows (4 hops + e2e × 4 clusters) | ~100 bytes | ~2 KB | ~20 KB |

Total: ~3 MB for 30 days — negligible.

### 11.2 Latency vs Precision

SLOG line timestamps from Go's `time.Now()` are millisecond-precision. Vector's `now()` is also millisecond-precision. ClickHouse `now64()` is millisecond-precision. Difference calculations are sub-millisecond accurate within a single host.

On Docker for Mac (Orbstack), all containers share the same clock (the host kernel). Clock skew between containers is not a concern.

### 11.3 Failure Modes

| Failure | Effect on Lineage | Detection | Recovery |
|---------|-------------------|-----------|----------|
| cc-connect stops emitting `trace_id` | Hop 2 latency unavailable, hop 3/4 still work | Missing `trace_id` in log lines | Fix cc-connect code, re-deploy |
| Vector `extract_trace_id` transform fails | All hops after Vector lose trace_id | Vector metrics show parse errors | Rollback transform change |
| Vector `clickhouse_lineage_metrics` sink fails | No lineage data but cc.message_log still gets data | CK table has zero new rows | Check CK connectivity, Vector logs |
| CK `infra.lineage_metrics` table full | Lineage data dropped (buffer overflow) | Vector metrics show dropped events | Increase TTL or table capacity |
| Grafana dashboard slow | Hop 4 latency high (self-referential — Grafana reports its own slowness) | Dashboard renders slowly | Optimize CK queries, add caching |
| Clock skew in multi-cluster setup | Hop 2/3 latencies inaccurate | Hop latency < 0 (impossible) | Ensure NTP sync across clusters |

### 11.4 Testing the Pipeline

```bash
# Step 1: Inject a test message via cc-connect
# (or simulate a log line that Vector will pick up)
docker exec feishu-bridge sh -c \
  'echo "time=2026-05-23T16:40:00Z level=INFO msg=\"message received\" trace_id=test_lineage_001 msg_id=test_lineage_001 platform=feishu session=feishu:oc_test:ou_test user=ou_test content_len=10" > /proc/1/fd/1'

# Step 2: Wait for Vector to pick up and write
sleep 10

# Step 3: Check lineage metrics
clickhouse-client --host host.orb.internal \
  --query "SELECT trace_id, latency_cc_to_vector, hop2_healthy
           FROM infra.lineage_metrics
           WHERE trace_id = 'test_lineage_001'"

# Expected: latency_cc_to_vector ~ 0.05 (50ms), hop2_healthy = 1

# Step 4: Check message_log correlation
clickhouse-client --host host.orb.internal \
  --query "SELECT trace_id, msg_id, event_type, event_time, ingested_at
           FROM cc.message_log
           WHERE trace_id = 'test_lineage_001'"
```

### 11.5 Production Readiness Checklist

- [ ] cc-connect emits `trace_id` on all message-related log lines
- [ ] Vector `extract_trace_id` transform is live and parsing correctly
- [ ] Vector `compute_vector_hop_latency` transform is recording `latency_cc_to_vector`
- [ ] `infra.lineage_metrics` table exists with correct schema and TTL
- [ ] hop 3 latency backfill cron is running
- [ ] Grafana Pipeline Health dashboard panels render < 200ms
- [ ] Alert rules are configured and firing on degradation
- [ ] Multi-cluster setup includes `cluster` tag in lineage metrics

---

## 12. Summary

| Aspect | Decision |
|--------|----------|
| Trace ID | Feishu `msg_id` used directly as `trace_id` (no mapping needed) |
| Hop 1 latency | From Feishu event timestamp (if available) to cc-connect log time |
| Hop 2 latency | Computed in Vector: `now()` (receive) - `event_time` (from log line) |
| Hop 3 latency | Computed in ClickHouse: `ingested_at` - `ts_vector_rcv` (post-insert backfill) |
| Hop 4 latency | Measured as Grafana panel render time, optionally written back via cron/WebHook |
| Storage | `infra.lineage_metrics` table; ~36 KB/day, 30-day TTL |
| Vector change | 2 new transforms (`extract_trace_id`, `compute_vector_hop_latency`) + 1 new sink |
| cc-connect change | Add `trace_id` field to all slog calls |
| Alert severity | P1: Hop 3 failure / no lineage data. P2: Trace stalled / e2e degraded. P3: Hop 2 degraded |

The key insight: **once a universal trace ID exists at the entry point, every downstream hop can compute its own latency relative to the previous hop's timestamp.** No distributed tracing infrastructure (OTel, Tempo) is required — the lineage is derived entirely from log line timestamps + Vector/CK timestamps. This is a lightweight, Zipkin-style approach that matches the project's existing observability stack.

---

/人◕ ‿‿ ◕人＼
