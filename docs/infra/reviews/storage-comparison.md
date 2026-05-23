---
decision: 现在就做
---

# Storage Backend Comparison: All Paths to ClickHouse

> **Status:** Master Comparison
> **Date:** 2026-05-23
> **Scope:** Exhaustive comparison of every observed data ingestion path into ClickHouse, covering latency, throughput, complexity, cost, and operational characteristics.

---

## Table of Contents

1. [Overview](#1-overview)
2. [CK Direct (HTTP INSERT)](#2-ck-direct-http-insert)
3. [Kafka -> CK](#3-kafka---ck)
4. [Vector -> CK](#4-vector---ck)
5. [Fluentd -> CK](#5-fluentd---ck)
6. [Prometheus -> CK](#6-prometheus---ck)
7. [OTel -> CK](#7-otel---ck)
8. [Grafana Alloy -> CK](#8-grafana-alloy---ck)
9. [Head-to-Head Comparison Matrix](#9-head-to-head-comparison-matrix)
10. [Decision Guide](#10-decision-guide)

---

## 1. Overview

This infra runs ClickHouse as the central telemetry lake. There are currently **seven distinct ingestion paths** proposed or deployed, each with different tradeoffs. This document compares them side by side so you can pick the right tool for each data source.

### Reference Architecture

```
Data Sources                                    Ingestion Paths                              Storage
==============                                  ===============                              =======

cc-connect (slog KV logs)  ────┬─── CK Direct (HTTP INSERT / nginx adapter)
                                ├─── Vector -> CK
                                ├─── Fluentd -> CK
                                ├─── OTel -> CK
                                └─── Alloy -> CK

Boss heartbeats (shell)    ────┬─── CK Direct (curl HTTP POST)                    ┌──────────┐
                                └─── Prometheus -> CK (via Alloy MV replacement)   │ClickHouse│
                                                                                    │          │
Boss hook events (Claude)  ───── CK Direct (emit-ck.sh HTTP POST)                  │ Prometheus│
                                                                                    │ samples  │
Container metrics          ───── Prometheus -> CK (remote write)                    │ otel_*   │
(cadvisor/node_exporter)                                                           │ cc.*     │
                                                                                    │ kyb.*    │
OTel spans (cc-connect,    ───── OTel -> CK (via OTel Collector -> Kafka -> CK)    │ patrol.* │
patrol, future services)                                                           │ boss.*   │
                                                                                    └──────────┘
Patrol health checks       ─────┬─── CK Direct (curl)
                                └─── Vector -> CK (via Docker logs)

All container logs         ─────┬─── Vector -> CK (docker_logs source)
                                ├─── Fluentd -> CK (tail source)
                                ├─── Alloy -> CK (loki.source.docker)
                                └─── OTel -> CK (via Collector + Kafka)

Infra service metrics      ───── Prometheus -> CK (remote write via Alloy or Prometheus)
```

---

## 2. CK Direct (HTTP INSERT)

### How It Works

The simplest possible path: an HTTP POST to ClickHouse's native HTTP endpoint with an INSERT query in the URL parameter.

```
Producer --HTTP POST--> ClickHouse (host.orb.internal:8123/?query=INSERT+INTO+table+FORMAT+JSONEachRow)
```

Currently deployed as:
- **emit-ck.sh** -- Claude hook events shell script POSTs JSON to CK
- **Boss heartbeats** -- shell loop (`while true; curl ...`) writes to `boss_heartbeats`
- **cc-hooks-direct-ck** -- proposed nginx adapter forwarding cc-connect webhooks to CK
- **Patrol curl** -- patrol agents POST health check results directly

### Latency

| Segment | Latency |
|---------|---------|
| Producer serialize | <1ms |
| HTTP round-trip (localhost) | 1-5ms |
| CK parse + insert | 0.5-2ms |
| **End-to-end (P50)** | **2-8ms** |
| **End-to-end (P99)** | **15-50ms** (under CK load) |

Lowest latency of all backends because there are zero intermediaries.

### Throughput

| Measure | Value |
|---------|-------|
| Sustained (single connection) | ~500 events/s |
| Sustained (10 connections) | ~3,000 events/s |
| Burst | ~5,000 events/s |
| Bottleneck | CK HTTP connection overhead per INSERT |

At current volume (~300 events/day for cc-connect, ~5000 events/day for heartbeats), this is **~0.01% of CK's HTTP capacity**. Throughput becomes a concern only above 100K events/day.

### Complexity

| Dimension | Score |
|-----------|-------|
| Components | **2** (producer + CK) |
| Config LOC | **~5 lines** (curl command or nginx.conf) |
| Parsing | None if producer emits JSON; regex/KV parser needed for slog |
| Error handling | None built-in (no retry, no buffer, no backpressure) |
| Monitoring | None built-in (silent failures if CK is down) |
| **Operational cost** | **Very low** (trivial to set up, nothing to maintain) |

### Cost

| Resource | Consumption |
|----------|-------------|
| Extra containers | 0 (unless nginx adapter used, then 1x nginx:alpine ~23MB image, ~5MB RAM) |
| CPU | Negligible (<0.01 core for curl, <0.05 core for nginx adapter) |
| RAM | <5 MB (curl) or ~5-10 MB (nginx) |
| Network | One small HTTP request per event (~500 bytes each) |

### Failure Modes

| Failure | Data Loss? | Recovery |
|---------|------------|----------|
| CK unreachable | Yes -- events lost during downtime | Retry in producer (if implemented); otherwise, loss is permanent |
| Producer crash | Yes -- in-flight POST lost | Container restart; gap in data |
| CK full/overloaded | Yes -- 503 responses, events dropped | Scale CK capacity |

### Best For

- **Single-producer, low-volume** pipelines (<10K events/day)
- **Latency-critical** monitoring alerts (heartbeats need <50ms end-to-end)
- **Prototyping** -- set up in 5 minutes, no extra infra
- **Replacing ad-hoc shell scripts** -- current emit-ck.sh pattern works fine

### Worst For

- Multi-producer scenarios (each producer needs its own retry logic)
- High-volume pipelines (>100K events/day)
- Pipelines requiring replay or buffering

---

## 3. Kafka -> CK

### How It Works

Kafka (Redpanda) serves as a durable message bus between producers and ClickHouse. ClickHouse's native Kafka Engine table consumes messages and materializes them into MergeTree tables.

```
Producer --Kafka produce--> Redpanda (host.orb.internal:9092) --Kafka Engine--> MergeTree
                                                                   ^
                                                         MATERIALIZED VIEW
```

Three topics defined:
- `cc.events` -- cc-connect observability events (3 partitions, 7d retention)
- `patrol.events` -- patrol heartbeats and anomalies (1 partition, 7d retention)
- `otel.spans` -- OTel trace spans (3 partitions, 3d retention)

### Latency

| Segment | Latency |
|---------|---------|
| Producer serialize + produce | 1-5ms |
| Kafka commit | 2-5ms (single broker, no replication) |
| Kafka Engine poll interval | ~100-500ms (CK polls every `kafka_poll_interval_ms`) |
| CK parse + insert | 0.5-2ms |
| **End-to-end (P50)** | **~100-500ms** |
| **End-to-end (P99)** | **~2-5s** (under CK load or Kafka rebalance) |

Kafka adds ~100-500ms of latency vs direct CK due to the poll-based consumption model.

### Throughput

| Measure | Value |
|---------|-------|
| Kafka produce (single partition) | ~10K msg/s |
| Kafka produce (3 partitions) | ~30K msg/s |
| CK Kafka Engine consume | ~5K-10K msg/s per consumer |
| Bottleneck | CK's Kafka Engine poll interval, not Kafka throughput |

At 3 partitions, the system handles **~30K msg/s** produce and **~15K-30K msg/s** consume. This is **~1000x** our current volume.

### Complexity

| Dimension | Score |
|-----------|-------|
| Components | **4** (producer + Redpanda + CK Kafka Engine + MV) |
| Config LOC | ~30 lines (Redpanda config + topic creation + CK DDL + producer integration) |
| Parsing | JSONEachRow into CK; no transform layer needed if producer emits clean JSON |
| Error handling | Kafka retention buffers 3-7 days; CK downtime = no data loss |
| Monitoring | Consumer lag, broker health, topic offsets (via Redpanda metrics) |
| **Operational cost** | **Medium** (one extra container + CK DDL + consumer lag monitoring) |

### Cost

| Resource | Consumption |
|----------|-------------|
| Extra containers | 1x Redpanda (~150MB image, ~256MB RAM in dev mode) |
| CPU | Negligible at current volume (<0.1 core) |
| RAM | ~256 MB (Redpanda dev container mode) |
| Disk | ~200 MB / 90 days (all topics combined at current volume) |
| Network | <1 KB/s average |

### Failure Modes

| Failure | Data Loss? | Recovery |
|---------|------------|----------|
| CK unreachable | **No** -- Kafka buffers up to retention window (3-7d) | Auto-recover when CK comes back; replay from committed offset |
| Kafka down | Yes -- events lost during outage but CK has all previously consumed data | Restart Redpanda; producer retry provides short-term buffer |
| Kafka volume loss | Yes -- unconsumed events in lost partitions | CK has all previously consumed data unaffected |
| CK permanently destroyed | **Partial** -- up to 7d replay from Kafka | Recreate CK + tables; reset consumer offset to earliest |

### Best For

- **Multi-producer** pipelines (cc-connect + patrol + future services)
- **High-volume** pipelines (>10K events/day)
- **Requiring replay** for post-mortem analysis or data reprocessing
- **CK downtime tolerance** -- events buffered in Kafka, no data loss
- **Multiple consumers** -- log storage + alerting + archive all read from same topic

### Worst For

- Single-producer, low-volume pipelines (Kafka is overkill)
- Sub-second latency requirements (adds 100-500ms)
- Resource-constrained environments (adds ~256MB RAM for Redpanda)

---

## 4. Vector -> CK

### How It Works

Vector collects logs from Docker containers via the Docker socket, applies transforms (parsing, enrichment, filtering), and writes to ClickHouse via the built-in `clickhouse` sink.

```
Docker containers (kyb.logs=true label) --docker_logs source--> Vector --transforms--> ClickHouse (cc.* tables)
                                                                   │
                                                              remap: parse_kv
                                                              remap: parse_go_duration
                                                              reduce: msg_id join
                                                              remap: add_cluster_metadata
```

### Latency

| Segment | Latency |
|---------|---------|
| Docker log emit -> Vector poll | ~500ms (Docker log buffer) |
| Vector transform | 1-5ms (KV parse, duration parse, enrich) |
| Vector batch wait | 0-10s (configurable via `batch.timeout_secs`) |
| CK HTTP INSERT | 1-5ms |
| **End-to-end (P50)** | **~1-5s** (dominated by batch wait) |
| **End-to-end (P99, batch timeout=10s)** | **~15s** |

**Tunable**: Setting `batch.timeout_secs=1` reduces latency to ~2-3s but increases CK connection overhead. Setting `batch.timeout_secs=10` improves throughput but adds latency.

### Throughput

| Measure | Value |
|---------|-------|
| Vector throughput (single instance) | ~500K-1M events/s |
| CK sink (with batching) | ~50K-100K INSERTs/s |
| Bottleneck | CK HTTP INSERT rate, not Vector processing |

Vector is extremely fast (Rust). At expected volume (<10K events/day), it runs at <1% capacity.

### Complexity

| Dimension | Score |
|-----------|-------|
| Components | **3** (Docker socket + Vector + CK) |
| Config LOC | **~250 lines** TOML (source + 5 transforms + 4 sinks + enrichment + buffer) |
| Parsing | Handles Go slog KV format, JSON, key=value; custom VRL for Go duration parsing |
| Error handling | Memory buffer (10K events) or disk buffer (100MB); drop-newest when full |
| Monitoring | Built-in `/metrics` endpoint, component-level error tracking |
| **Operational cost** | **Medium** (one container to monitor, config to maintain, complex transforms) |

### Cost

| Resource | Consumption |
|----------|-------------|
| Extra containers | 1x Vector (~50MB alpine image, ~15MB RAM idle, ~40MB under load at our volume) |
| CPU | 0.1-0.5 cores |
| RAM | ~15-40 MB |
| Disk (buffer) | 0-100 MB (only when CK is unreachable) |

### Failure Modes

| Failure | Data Loss? | Recovery |
|---------|------------|----------|
| CK unreachable | No (buffer up to 10K/100MB events, then drop-newest) | Auto-reconnect; oldest events lost on sustained outage |
| Vector crashes | Yes -- in-flight buffered events lost | Docker auto-restart; transient data loss |
| Very high volume spike | Partial -- buffer fills, drops oldest | Scale buffer or CK capacity |

### Best For

- **Log-specific pipelines** with complex parsing requirements (KV, JSON, regex, duration parsing)
- **Docker log discovery** -- auto-discovers containers with labels
- **Pipeline with transforms** -- VRL is a powerful transform language for log parsing
- **Already deployed** -- Vector is currently the planned pipeline for cc-connect log ingestion

### Worst For

- Metrics or traces (not designed for Prometheus scraping or OTel span ingestion)
- Simple single-producer paths (overkill -- use CK Direct)
- Dashboards needing real-time data (Vector adds batch latency)

---

## 5. Fluentd -> CK

### How It Works

Fluentd tails Docker JSON log files from the host filesystem (`/var/lib/docker/containers/*/*-json.log`), parses them with regex or JSON parsers, and writes to ClickHouse via the `fluent-plugin-clickhouse` gem. Multi-cluster forwarding uses Fluentd's native `forward` protocol.

```
Docker json-log files --tail source--> Fluentd --regex/json parser--> ClickHouse (fluent-plugin-clickhouse)
                                                       │
                                              forward to central (remote clusters)
```

### Latency

| Segment | Latency |
|---------|---------|
| File poll interval | ~500ms-1s |
| Fluentd parsing | 2-10ms (Ruby, regex-based) |
| Fluentd batch/retry buffer | 0-5s (configurable `flush_interval`) |
| CK INSERT (via gem) | 3-10ms |
| **End-to-end (P50)** | **~1-6s** |
| **End-to-end (P99)** | **~10-20s** |

Fluentd is slower than Vector for parsing (Ruby vs Rust) but comparable for throughput at low volume.

### Throughput

| Measure | Value |
|---------|-------|
| Fluentd throughput (single instance) | ~50-100K events/s |
| CK sink (community gem) | ~10K-50K INSERTs/s |
| Bottleneck | Ruby regex parsing for complex formats |

### Complexity

| Dimension | Score |
|-----------|-------|
| Components | **3** (Docker log files + Fluentd + CK) |
| Config LOC | **~100-150 lines** (Ruby DSL + XML-like `<match>` blocks) |
| Parsing | Regex, JSON, key=value via `filter_parser`; richer ecosystem than Vector |
| Error handling | File-based buffer with exponential backoff retry, `retry_forever` support |
| Monitoring | `monitor_agent` HTTP + Prometheus plugin |
| **Operational cost** | **Medium-High** (Ruby ecosystem, gem maintenance, more complex config format) |

### Cost

| Resource | Consumption |
|----------|-------------|
| Extra containers | 1x Fluentd (~80MB debian image, ~40-80MB RAM idle, ~120-200MB under load) |
| CPU | ~5-10% of 1 core (Ruby runtime) |
| RAM | ~40-200 MB (higher than Vector due to Ruby runtime) |
| Disk (buffer) | 0-100 MB (configurable) |

### Failure Modes

| Failure | Data Loss? | Recovery |
|---------|------------|----------|
| CK unreachable | No -- file buffer with `retry_forever` | Auto-reconnect; exponential backoff |
| Fluentd crashes | Yes -- in-memory events lost | Docker auto-restart; file buffer survives (disk buffer) |
| Docker log rotation | No -- pos_file tracks inode/offset; handles rotation gracefully | Automatic |

### Best For

- **Multi-cluster forwarding** -- Fluentd's `forward` protocol is the most mature option for inter-cluster log shipping
- **Diverse parser needs** -- richest regex/parser ecosystem (1000+ plugins)
- **Ruby-centric teams** -- config is Ruby DSL, familiar to Ruby developers
- **Remote cluster agent** -- current recommendation per `fluentd-pipeline.md`: Fluentd on remote clusters where mature forward protocol adds value

### Worst For

- Resource-constrained environments (uses more memory than Vector)
- High-throughput pipelines (Ruby bottleneck vs Rust)
- Teams unfamiliar with Ruby DSL config format
- Simpler pipelines (Vector's TOML is easier to understand)

---

## 6. Prometheus -> CK

### How It Works

**Three sub-paths exist:**

#### 6a. Prometheus scrape -> Prometheus TSDB -> CK remote write

```
Exporters (node_exporter, cadvisor, app /metrics)
    │ Prometheus scrape (15s interval)
    ▼
Prometheus TSDB (kyb-infra-prometheus)
    │ Prometheus remote write
    ▼
ClickHouse (/prometheus/write endpoint) -> prometheus_samples table
```

#### 6b. Alloy scrape -> Prometheus remote write -> CK (No Prometheus server)

```
Exporters (container /metrics via Docker labels)
    │ Alloy prometheus.scrape (15s interval)
    ▼
Grafana Alloy
    │ Prometheus remote write (built-in WAL + retry)
    ▼
ClickHouse (/prometheus/write endpoint) -> prometheus_samples table
```

#### 6c. Heartbeat loop -> CK (current, being replaced)

```
Boss shell loop (while true; curl ...)
    │ HTTP POST /?query=INSERT+INTO+boss_heartbeats
    ▼
ClickHouse
```

### Latency (Path 6a -- Prometheus server)

| Segment | Latency |
|---------|---------|
| Scrape interval | 15-30s (configurable) |
| Prometheus TSDB write | ~1ms |
| Remote write batch | 0-5s (configurable `queue.max_shards`) |
| CK remote write ingest | 1-5ms |
| **End-to-end (P50)** | **~15-35s** |
| **End-to-end (P99)** | **~60s** |

Prometheus metrics are **not real-time**. They are sampled on a 15-30s interval and batched for remote write. This is acceptable for alerting and dashboards but not for per-event latency.

### Latency (Path 6b -- Alloy direct)

| Segment | Latency |
|---------|---------|
| Scrape interval | 15s (configurable) |
| Alloy WAL + batch | 0-5s |
| CK remote write | 1-5ms |
| **End-to-end (P50)** | **15-20s** |
| **End-to-end (P99)** | **60s+** |

Similar latency profile. The scrape interval dominates.

### Throughput

| Measure | Value |
|---------|-------|
| Prometheus scrape | ~10K time series / instance |
| Remote write to CK | ~100K samples/s |
| CK Prometheus endpoint | Handles ~1M samples/s (columnar, batch-optimized) |
| Bottleneck | Scrape interval, not throughput |

At ~1,200 estimated time series, Prometheus is at **~0.2% capacity**.

### Complexity

| Dimension | Score |
|-----------|-------|
| Components (6a) | **4+** (exporters + Prometheus + CK + Alertmanager, optional cadvisor, node_exporter) |
| Components (6b) | **3** (Alloy + CK + exporters, no Prometheus server) |
| Config LOC (6a) | ~200 lines YAML (Prometheus config + scrape configs + alert rules + Alertmanager) |
| Config LOC (6b) | ~100 lines River (Alloy config + discovery + scrape + relabel + remote_write) |
| Parsing | Native Prometheus format; no parsing needed |
| Error handling | Prometheus retries scrapes; remote write WAL for CK outages |
| Monitoring | Prometheus self-scrapes + Alertmanager for alerts |
| **Operational cost** | **Medium** (6a) or **Low** (6b -- Alloy replaces Prometheus server) |

### Cost

| Resource | 6a (Prometheus Server) | 6b (Alloy only) |
|----------|----------------------|-----------------|
| Extra containers | Prometheus + Alertmanager + exporters (5-8 containers) | Alloy + exporters (2-3 containers) |
| Image size | ~60 MB (Prometheus) + ~50 MB (Alertmanager) + ~30 MB each exporter = ~200-400 MB total | ~50 MB (Alloy) + ~30 MB each exporter = ~110-200 MB |
| RAM (total) | ~500 MB (Prometheus: 256MB, Alertmanager: 64MB, exporters: ~180MB) | ~150-200 MB (Alloy: 50MB, exporters: ~100-150MB) |
| Disk | 2-10 GB (Prometheus TSDB, 30d retention) | ~500 MB (Alloy WAL) |

### Failure Modes

| Failure | Data Loss? | Recovery |
|---------|------------|----------|
| CK unreachable (6a) | No -- Prometheus buffers in TSDB (30d) | Remote write resends when CK recovers |
| CK unreachable (6b) | No -- Alloy WAL buffers | Replays when CK recovers |
| Prometheus/Alloy crash | Minutes of data (scrape gap) | Restart; next scrape fills gap |
| Exporter crash | No -- Prometheus retries scrape; stale data after timeout | Auto-restart exporter |

### Best For

- **Metrics pipelines** -- CPU, memory, disk, network, application counters/histograms
- **Real-time alerting** -- Alertmanager evaluates rules on Prometheus data
- **Long-term metrics archive** -- CK stores Prometheus remote write data for arbitrary retention with downsampling
- **Dashboards** -- Grafana Prometheus datasource for instant queries, CK for historical

### Worst For

- Event-level logs (not designed for log text or structured events)
- Sub-second latency needs (scrape interval adds 15-30s minimum)
- Per-event tracing (use OTel for spans)

---

## 7. OTel -> CK

### How It Works

Applications (cc-connect, patrol) emit OTel traces via OTLP to an OTel Collector. The collector exports spans to a Kafka topic (`otel.spans`), and ClickHouse consumes them via a Kafka Engine table with a MATERIALIZED VIEW extracting attributes into columns.

```
Application (OTel SDK) --OTLP gRPC/HTTP--> OTel Collector --Kafka exporter--> Redpanda (otel.spans)
                                                                                  │
                                                                      ClickHouse Kafka Engine
                                                                                  │
                                                                      MATERIALIZED VIEW
                                                                                  │
                                                                      otel.span_log (MergeTree)
```

### Latency

| Segment | Latency |
|---------|---------|
| OTel SDK export | 1-5ms (batch export, default 1s interval) |
| OTel Collector process | 1-2ms (batch + attributes processor) |
| Kafka produce | 2-5ms |
| CK Kafka Engine poll | 100-500ms |
| MV attribute extraction | 1-5ms |
| **End-to-end (P50)** | **~1-3s** |
| **End-to-end (P99)** | **~5-10s** |

The Kafka hop adds latency versus direct OTel -> Tempo, but enables replay and decouples ingestion.

### Throughput

| Measure | Value |
|---------|-------|
| OTel Collector throughput | ~100K spans/s |
| Kafka produce | ~30K msg/s (3 partitions) |
| CK Kafka Engine consume | ~5K-15K spans/s |
| Bottleneck | CK attribute extraction in MV, not transport |

At expected ~540 spans/day, this is **~0.001% capacity**.

### Complexity

| Dimension | Score |
|-----------|-------|
| Components | **5** (app OTel SDK + OTel Collector + Redpanda + CK Kafka Engine + MV) |
| Config LOC | ~100 lines (Collector YAML + CK DDL + topic creation) |
| Parsing | OTLP protobuf -> JSON (Collector serializes); CK extracts attributes via JSON |
| Error handling | Kafka buffers 3d; CK Kafka Engine skips broken messages; Collector batch+retry |
| Monitoring | Collector `/metrics`, Kafka consumer lag, CK insert counts |
| **Operational cost** | **High** (most complex pipeline: 5 components, schema extraction, attribute management) |

### Cost

| Resource | Consumption |
|----------|-------------|
| Extra containers | OTel Collector (~50MB image, ~50MB RAM) + Kafka (shared, ~256MB RAM) |
| CPU | <0.1 core (collector is lightweight) |
| RAM | ~50-100 MB (collector + shared Kafka) |
| Disk | ~1.5 MB (3d Kafka retention at 540 spans/day); negligible |
| Network | Minimal (~500 KB/day of spans) |

### Failure Modes

| Failure | Data Loss? | Recovery |
|---------|------------|----------|
| CK unreachable | No -- Kafka buffers up to 3d retention | Auto-recover; Kafka consumer resumes from committed offset |
| Kafka down | Yes -- spans lost during outage | Restart Redpanda; OTel SDK drops spans on export failure (default behavior) |
| Collector crash | Yes -- in-flight spans lost | Docker auto-restart; spans in SDK buffer survive (configurable) |

### Best For

- **Distributed tracing** -- trace tree reconstruction, span-level observability
- **Multi-service correlation** -- trace_id across cc-connect, patrol, future MCP services
- **Future-proofing** -- OTel is the industry standard; any new Go/Rust service can emit OTLP
- **Single unified trace store** -- CK replaces Tempo, eliminating a separate backend

### Worst For

- Log pipelines (use Vector or Fluentd, which are purpose-built for log parsing)
- Metrics (use Prometheus, which is purpose-built for counters/histograms)
- Simple single-service tracing with <100 spans/day (overkill)
- Teams needing TraceQL (CK's SQL-based trace query is more verbose)

---

## 8. Grafana Alloy -> CK

### How It Works

Grafana Alloy is a single binary that combines Prometheus scraping, OTel collection, and log collection. It replaces Prometheus server + OTel Collector + (eventually) Vector in a single container.

```
Docker containers (telemetry=enabled label)
    │ discovery.docker
    ▼
Grafana Alloy
    ├── prometheus.scrape (metrics, 15s interval)
    │   └── prometheus.remote_write -> CK (/prometheus/write)
    ├── otelcol.receiver.otlp (traces, future)
    │   └── otelcol.exporter.otlphttp -> CK (/otel/v1/traces)
    └── loki.source.docker (logs, Phase 1 -> Vector, Phase 2 -> CK natively)
        └── loki.process (parsing transforms)
            └── loki.write -> CK (or Vector bridge)
```

### Latency

| Pipeline | P50 Latency | Notes |
|----------|-------------|-------|
| Metrics (prometheus.scrape -> remote_write) | 15-30s | Scrape interval dominates |
| Logs (loki.source.docker -> loki.process -> CK) | 2-10s | Depends on batch/flush interval |
| Traces (otelcol.receiver.otlp -> CK) | 1-3s | Via OTLP HTTP to CK endpoint |

Alloy does not improve latency over individual components; it consolidates them.

### Throughput

| Measure | Value |
|---------|-------|
| Metrics scrape | ~7,500 time series / instance |
| Log processing | ~50K lines/s |
| Trace ingest | ~50K spans/s |
| Bottleneck | Alloy is single-binary; all pipelines share CPU/memory |

### Complexity

| Dimension | Score |
|-----------|-------|
| Components | **3** (Docker socket + Alloy + CK) |
| Config LOC | **~200-300 lines** River (discovery, metrics pipeline, logs pipeline, traces pipeline) |
| Parsing | `loki.process` with `logfmt`, `json`, `regex` stages; native OTLP; native Prometheus |
| Error handling | WAL-based buffering for remote write; retry with backoff; disk buffer for logs |
| Monitoring | Built-in `/metrics` endpoint per component; self-metrics in Grafana |
| **Operational cost** | **Low** (single container, single config; replaces 3-4 agents) |

### Cost

| Resource | Consumption |
|----------|-------------|
| Extra containers | **1** (Alloy) instead of 3-4 (Prometheus + OTel Collector + Vector) |
| Image size | ~50 MB (single static binary) |
| RAM | ~30-50 MB idle, ~150 MB under load |
| CPU | 0.05-0.1 core idle, 0.3-0.5 under load |
| Disk (WAL) | ~500 MB |
| **Total infra savings** | **~2-3 fewer containers, ~200-400 MB less RAM vs running separate agents** |

### Failure Modes

| Failure | Data Loss? | Recovery |
|---------|------------|----------|
| CK unreachable | No -- WAL/disk buffer for metrics + logs | Replays when CK recovers |
| Alloy crash | Partial -- WAL survives, in-flight logs lost | Docker auto-restart |
| Docker socket unavailable | No new container discovery | Alloy retries; existing scrape targets continue working |

### Best For

- **Unified telemetry collection** -- metrics, logs, and traces from a single agent
- **Infrastructure consolidation** -- replacing Prometheus + OTel Collector + Vector
- **Docker-native auto-discovery** -- `discovery.docker` auto-adds new containers
- **Per-cluster deployment** -- one Alloy per cluster replaces 3-4 agents per cluster

### Worst For

- Existing single-purpose pipelines already working (migration cost may outweigh benefit)
- Teams already invested in Vector's VRL transform ecosystem (River is different)
- The current Alloy -> ClickHouse log path is still immature (requires Vector bridge in Phase 1)

---

## 9. Head-to-Head Comparison Matrix

### Latency & Throughput

| Backend | P50 E2E Latency | P99 E2E Latency | Max Throughput | Latency Profile |
|---------|----------------|----------------|---------------|-----------------|
| CK Direct | **2-8ms** | **15-50ms** | ~3K events/s | **Real-time** (sub-10ms) |
| Kafka -> CK | 100-500ms | 2-5s | ~30K msg/s | Near-real-time |
| Vector -> CK | 1-5s | ~15s | ~500K events/s | **Batch** (tunable 1-10s) |
| Fluentd -> CK | 1-6s | 10-20s | ~100K events/s | Batch (slower than Vector) |
| Prometheus -> CK | 15-30s | ~60s | ~100K samples/s | **Sampled** (scrape interval bound) |
| OTel -> CK | 1-3s | 5-10s | ~15K spans/s | Near-real-time (Kafka bound) |
| Alloy -> CK | 15-30s | 60s | ~7.5K series | Sampled (scrape interval bound) |

**Key insight**: Latency is dominated by the slowest hop in each path. CK Direct is the only real-time path. All buffered/collected paths add 1-60s.

### Complexity & Operational Cost

| Backend | Components | Config LOC | Parsing Engine | Error Recovery | Operational Cost |
|---------|-----------|-----------|----------------|---------------|------------------|
| CK Direct | 2 | ~5 | None needed | None built-in | **Very Low** |
| Kafka -> CK | 4 | ~30 | JSONEachRow (none) | Kafka retention + replay | Medium |
| Vector -> CK | 3 | ~250 | VRL (powerful) | Memory/disk buffer | Medium |
| Fluentd -> CK | 3 | ~100-150 | Ruby regex (rich) | File buffer + retry_forever | Medium-High |
| Prometheus -> CK (6a) | 4+ | ~200 | None needed | WAL + TSDB buffer | Medium |
| Prometheus -> CK (6b) | 3 | ~100 | River (decent) | Alloy WAL | Low |
| OTel -> CK | 5 | ~100 | OTLP protobuf + JSON | Kafka retention | **High** |
| Alloy -> CK | 3 | ~200-300 | River (stages) | WAL + disk buffer | **Low** |

### Resource Cost (per instance)

| Backend | Containers | Image Size | RAM Idle | RAM Peak | Disk |
|---------|-----------|-----------|----------|----------|------|
| CK Direct | 0 | 0 | 0 | 0 | 0 |
| Kafka -> CK | **1** (Redpanda) | 150 MB | 256 MB | 256 MB | ~200 MB / 90d |
| Vector -> CK | 1 | 50 MB | 15 MB | 40 MB | 0-100 MB |
| Fluentd -> CK | 1 | 80 MB | 80 MB | 200 MB | 0-100 MB |
| Prometheus -> CK (6a) | 5-8 | 200-400 MB | 500 MB | 800 MB | 2-10 GB |
| Prometheus -> CK (6b) | 2-3 | 110-200 MB | 150 MB | 200 MB | 500 MB |
| OTel -> CK | 2 (+ shared Kafka) | 200 MB | 306 MB | 356 MB | ~1.5 MB |
| Alloy -> CK | 1 | 50 MB | 50 MB | 150 MB | 500 MB |

### Data Resiliency

| Backend | CK Down | Producer Crash | Replay | Data Guarantee |
|---------|---------|---------------|--------|----------------|
| CK Direct | **Data loss** | In-flight loss | None | At-most-once |
| Kafka -> CK | **No loss** (Kafka buffers) | In-flight loss (SDK dependant) | Yes (3-7d window) | At-least-once |
| Vector -> CK | No loss (buffer fills) | In-flight loss | None | At-most-once (buffer) |
| Fluentd -> CK | No loss (disk buffer) | Disk buffer survives | None | At-least-once (disk buffer) |
| Prometheus -> CK (6a) | No loss (TSDB buffers) | Minutes gap | None | At-most-once (scrape) |
| Prometheus -> CK (6b) | No loss (WAL buffers) | WAL survives | None | At-least-once (WAL) |
| OTel -> CK | No loss (Kafka buffers) | In-flight loss | Yes (3d window) | At-least-once |
| Alloy -> CK | No loss (WAL buffers) | WAL survives | None | At-least-once (WAL) |

### Pipeline Capabilities

| Capability | CK Direct | Kafka -> CK | Vector -> CK | Fluentd -> CK | Prom -> CK | OTel -> CK | Alloy -> CK |
|-----------|-----------|-------------|-------------|--------------|-----------|-----------|-------------|
| Logs | Yes | Yes | **Best** | **Best** | No | No | Good |
| Metrics | No | No (can carry but unfitting) | No | No | **Best** | No | **Best** |
| Traces | No | Yes | No | No | No | **Best** | Good (future) |
| Multi-cluster forward | No | No (manual) | Via `vector` source/sink | **Best** (`forward` native) | Via remote targets | Via OTLP | Via remote write |
| Auto-discovery | No | No | **Label-based** (docker_logs) | **Label-based** (tail + filter) | Static config | Static config | **Label-based** (discovery.docker) |
| Complex transforms | No | No (pre-transform in producer) | **Best** (VRL: KV, regex, JSON, duration) | Good (Ruby regex, multi-format) | No | No (attributes already structured) | Good (River stages: logfmt, regex, JSON) |
| Schema drift handling | Manual (ALTER TABLE) | Manual (ALTER TABLE) | Manual (VRL update) | Manual (regex update) | N/A (label-based) | **Best** (`raw_payload` + attribute extraction) | Manual (River update) |
| Alerting | None | Via Kafka consumer | None | None | **Best** (built-in Alertmanager) | None | Via Grafana |
| Grafana integration | ClickHouse DS | ClickHouse DS | ClickHouse DS | ClickHouse DS | **Best** (Prometheus DS native) | ClickHouse DS (trace view) | ClickHouse DS + Alloy DS |

---

## 10. Decision Guide

### For Each Data Type

| If you need... | Use... | Why |
|----------------|--------|-----|
| **Event logs** (cc-connect, patrol, MCP) with complex parsing | **Vector -> CK** | VRL parsing is the most powerful, proven in this codebase, label-based Docker discovery |
| **Simple low-volume heartbeats** (boss heartbeats, hook events) | **CK Direct** | 5ms latency, zero infrastructure, proven pattern (emit-ck.sh already works) |
| **Multi-producer event bus** with replay requirement | **Kafka -> CK** | Durable buffer, multi-consumer, replay for post-mortem |
| **Multi-cluster log forwarding** from remote clusters | **Fluentd -> CK** | Mature forward protocol, rich parser ecosystem for diverse remote log formats |
| **Infrastructure metrics** (CPU, memory, disk, network) | **Prometheus -> CK** via **Alloy** | Standard Prometheus scrape model, Alloy consolidates the agent, CK stores long-term |
| **Application metrics** (counters, histograms, latency) | **Prometheus -> CK** via **Alloy** (scrape app /metrics) | Same as infra metrics; Prometheus histogram_quantile for latency |
| **Distributed tracing** (end-to-end request tracking) | **OTel -> Kafka -> CK** | OTel SDKs produce OTel spans; Kafka provides decoupling; CK stores for SQL query |
| **Single unified agent** for all telemetry on a cluster | **Alloy -> CK** | Metrics + logs + traces from one binary, one config, one container; replaces 3-4 agents |

### Recommended Stack Per Cluster

| Cluster | Recommended Storage Backends | Rationale |
|---------|----------------------------|-----------|
| **Mac/Orbstack** (central) | **Alloy -> CK** (metrics + traces) + **Vector -> CK** (logs, keep existing) + **CK Direct** (heartbeats, keep existing) | Alloy replaces Prometheus server for metrics; Vector handles complex log parsing; CK Direct for heartbeats (already working, zero migration cost) |
| **Aliyun/Office** (remote) | **Fluentd -> CK** (logs) + **Alloy -> CK** (metrics) + **CK Direct** (heartbeats via curl) | Fluentd for mature forward to central; Alloy for local metrics; heartbeats stay as curl (simple, proven) |
| **New sandbox agents** (ephemeral) | **CK Direct** only | Ephemeral containers don't need persistent pipeline; on-demand log retrieval via `kyb exec` |

### Migration Priority

```
Phase 1 (Now - Deployed):
  CK Direct: emit-ck.sh (hooks), boss heartbeats (curl) -- working, keep
  Vector: cc-connect Docker logs pipeline -- design ready, not yet deployed

Phase 2 (Next):
  Alloy: Add to Mac/Orbstack for metrics pipeline
  Prometheus -> CK: via Alloy (metrics dashboard + alerting)

Phase 3 (Soon):
  Kafka: Deploy Redpanda for event bus
  OTel -> Kafka -> CK: Trace ingestion (enable when services emit OTLP)

Phase 4 (Future):
  Fluentd: Deploy on remote clusters for log forwarding
  Vector replacement: Optionally port log parsing to Alloy Phase 2
```

### Anti-Patterns

| Don't Do This | Instead |
|---------------|---------|
| Use Kafka for a single producer with <100 events/day | CK Direct (simpler, faster, no extra infra) |
| Use Vector for metrics (cadvisor scraping) | Prometheus -> CK via Alloy (Metrics is Prometheus's job; Vector is not a metrics collector) |
| Use Fluentd on resource-constrained hosts (<1GB RAM) | Vector or Alloy (lower memory footprint) |
| Use OTel -> CK for logs (OTel is designed for traces, not log text) | Vector or Fluentd (purpose-built log collectors with KV/regex/JSON parsing) |
| Run Prometheus + OTel Collector + Vector + Fluentd on the same host | Consolidate to Alloy (one agent for metrics+traces+logs; keep Vector for log parsing if needed) |
| Use CK Direct for high-volume (>100K events/day) without buffering | Add Kafka or Vector for buffer + batching |

---

> **Summary**: No single backend is best for all workloads. CK Direct is the fastest but least resilient; Kafka->CK is the most resilient but adds latency; Prometheus->CK is purpose-built for metrics; OTel->CK for traces; Vector/Fluentd for logs; Alloy for consolidation. The recommended stack uses Alloy for metrics, Vector for log parsing, Kafka for event bus buffering, and CK Direct for simple low-volume heartbeats. Deploy incrementally -- start with what's already working (CK Direct + Vector), then add Alloy, then Kafka+OTel.

> ／人◕ ‿‿ ◕人＼
