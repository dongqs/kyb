---
decision: 稍后做
---

# Grafana Alloy as Unified Telemetry Collector

> **Status:** Architecture Design / Implementation Proposal
> **Date:** 2026-05-23
> **Context:** Replace piecemeal scraping (curl-to-CK, Vector, ad-hoc scripts) with a single OpenTelemetry-native collector. Alloy collects metrics, logs, and traces from every cluster service and forwards to ClickHouse / Prometheus / Tempo.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Why Grafana Alloy](#2-why-grafana-alloy)
3. [Architecture Overview](#3-architecture-overview)
4. [Telemetry Pipelines](#4-telemetry-pipelines)
5. [Deployment per Cluster](#5-deployment-per-cluster)
6. [Alloy Configuration](#6-alloy-configuration)
7. [ClickHouse Schemas](#7-clickhouse-schemas)
8. [Grafana Data Sources & Dashboards](#8-grafana-data-sources--dashboards)
9. [Migration from Current Setup](#9-migration-from-current-setup)
10. [Operations & Runbook](#10-operations--runbook)
11. [Recommendations](#11-recommendations)
12. [Verdict](#12-verdict)

---

## 1. Problem Statement

### Current State

The infra observability stack has grown organically and now has four separate collection mechanisms:

| Collector | What it collects | Destination | Protocol |
|-----------|-----------------|-------------|----------|
| `curl` in heartbeat loops | Boss heartbeats (docker_running, disk, etc.) | ClickHouse (HTTP) | Native HTTP INSERT |
| Vector (one pipeline) | cc-connect structured logs | ClickHouse | Vector → HTTP |
| Ad-hoc `docker stats` | Container resource usage (manual) | None | N/A |
| Nothing | Prometheus metrics from containers | None | N/A |
| Nothing | Distributed traces | None | N/A |

**Problems:**

1. **No unified metrics pipeline** — Prometheus exporters exist but no Prometheus server or collector to scrape them. Container CPU/mem/disk is invisible unless manually inspected.
2. **No trace collection** — Zero distributed tracing. When a feishu message -> cc-connect -> Claude API roundtrip degrades, there is no trace to pinpoint the bottleneck.
3. **Vector is single-purpose** — Vector excels at log parsing but is not designed for metrics scraping or trace collection. Running three separate agents (Vector + Prometheus + OTel Collector) adds operational burden.
4. **Each cluster is siloed** — Heartbeats go to central CK but container-level telemetry stays on the cluster. No way to compare "CPU on Aliyun vs Office vs Mac" in one Grafana view.
5. **No auto-discovery** — Adding a new container or service requires manual config changes. No service discovery or container label-based routing.

### Requirements

- **Unified agent** — one daemon per cluster that handles metrics / logs / traces
- **Prometheus-native scraping** — auto-discover and scrape metrics from all containers and system services
- **OpenTelemetry-native** — support OTLP for traces, and eventually replace Vector for logs
- **ClickHouse as telemetry lake** — all telemetry lands in CK for long-term storage and Grafana querying
- **Zero-config for new containers** — container labels drive pipeline routing, not static config
- **Lightweight** — runs in a Docker container, minimal CPU/mem overhead (< 100 MB RAM, < 0.1 core typical)

---

## 2. Why Grafana Alloy

### Comparison

| Feature | Grafana Alloy | Prometheus + OTel Collector + Vector | Vector only | Prometheus only |
|---------|--------------|--------------------------------------|-------------|-----------------|
| **Metrics scraping** | Yes (Prometheus receiver) | Yes (3 separate agents) | No | Yes |
| **Log collection** | Yes (Loki receiver, filelog) | Yes (Vector) | Yes | No |
| **Trace collection** | Yes (OTLP receiver) | Yes (OTel Collector) | No | No |
| **OTLP native** | Yes (built-in) | Yes (OTel Collector) | No | No |
| **Prometheus remote write** | Yes | Yes (Prometheus) | No | Yes |
| **ClickHouse output** | Yes (via `otelcol` exporter or Prometheus remote write to CK) | Via Vector | Yes | No |
| **Single binary** | Yes | No (3 daemons) | Yes | N/A |
| **Reload without restart** | Yes (SIGHUP / `/-/reload`) | Config-dependent | Yes | Yes |
| **Docker labels discovery** | Yes (discovery.docker) | Manual or separate sd | Limited | Limited |
| **Weight** | ~50 MB binary | ~200 MB total (3 agents) | ~30 MB | ~60 MB |
| **RAM idle** | ~30-50 MB | ~100-150 MB | ~10 MB | ~20 MB |
| **Config format** | River (readable, blocks) | Multiple formats | TOML | YAML |
| **License** | AGPLv3 (free for internal use) | Apache 2.0 / MIT | MPL 2.0 | Apache 2.0 |

**Why Alloy wins for this infra:**

1. **One agent replaces three** — metrics, logs, and traces from a single binary with a single config. Fewer containers to manage, less memory, fewer failure modes.
2. **Docker service discovery** — `discovery.docker` auto-discovers local containers and their labels. New services appear in Grafana automatically.
3. **ClickHouse is both metrics backend and log backend** — Alloy can write Prometheus remote-wire format directly to ClickHouse via the `prometheus.remote_write` exporter (using ClickHouse's Prometheus protocol support), or via the OpenTelemetry exporter to OTel-native tables. Both work.
4. **Future-proof OTLP** — As we add more Go services (healthcheck, webhook endpoints), they can emit OTLP traces directly to Alloy without additional agents.
5. **Grafana-native** — Built by Grafana Labs, best-in-class integration with Grafana dashboards, Grafana Cloud, and the LGTM stack.

### Trade-offs

- **River config language** — new to learn. It is a declarative block language, similar to HCL but lighter. The learning curve is ~1 hour.
- **Vector replacement is incremental** — Vector already works for cc-connect logs. Alloy should parallel-run with Vector initially, not replace it day one.
- **ClickHouse Prometheus protocol** — ClickHouse's Prometheus remote-write endpoint is in the `clickhouse-prometheus` proxy or via `PrometheusExporter` in recent CK versions. On our CK version (23.x+), we can use the `prometheus.remote_write` output with `url = "http://clickhouse:8123/prometheus/write"`.

---

## 3. Architecture Overview

### High-Level Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Cluster (Mac / Aliyun / Office)           │
│                                                              │
│  ┌──────────┐   ┌──────────────┐   ┌─────────────────────┐  │
│  │ Docker    │   │ System       │   │ Application pods    │  │
│  │ containers│──>│ (cadvisor /  │   │ (OTLP SDK /         │  │
│  │ (labels)  │   │  node_exporter)  │  Prometheus client) │  │
│  └──────────┘   └──────────────┘   └─────────────────────┘  │
│       │               │                      │               │
│       ▼               ▼                      ▼               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              Grafana Alloy (single container)           │ │
│  │                                                         │ │
│  │  discovery.docker ──> prometheus.scrape ──>             │ │
│  │  discovery.kubernetes (future) ──>                      │ │
│  │  otelcol.receiver.otlp ──>                              │ │
│  │  loki.source.file ──> loki.process ──>                  │ │
│  │                                                         │ │
│  │  ┌────────────┐  ┌──────────┐  ┌───────────────┐       │ │
│  │  │ Metrics    │  │ Logs     │  │ Traces        │       │ │
│  │  │ pipeline   │  │ pipeline │  │ pipeline      │       │ │
│  │  └─────┬──────┘  └────┬─────┘  └──────┬────────┘       │ │
│  └────────┼──────────────┼───────────────┼─────────────────┘ │
│           │              │               │                    │
└───────────┼──────────────┼───────────────┼────────────────────┘
            │              │               │
            ▼              ▼               ▼
     ┌──────────┐   ┌──────────┐   ┌──────────┐
     │ ClickHouse   │ ClickHouse   │ ClickHouse │
     │ (metrics) │   │ (logs)    │   │ (traces)  │
     └──────────┘   └──────────┘   └──────────┘
            │              │               │
            ▼              ▼               ▼
     ┌─────────────────────────────────────────────┐
     │              Grafana (on Mac)                │
     │  Dashboards │ Explore │ Alerts               │
     └─────────────────────────────────────────────┘
```

### Key Design Decisions

1. **Alloy runs as a sidecar on each cluster**, not centrally on Mac. This keeps collection local: if the central Mac goes down, each cluster still collects and buffers telemetry. The cluster boss creates and supervises the Alloy container.

2. **ClickHouse is the single telemetry backend** for now. Prometheus itself is not deployed — ClickHouse speaks the Prometheus remote-write protocol natively (via `PrometheusExporter` or the `/prometheus/write` HTTP endpoint), and Grafana can query CK directly with the ClickHouse datasource plugin. This avoids operating a separate Prometheus server.

3. **Buffering is on the client side** — Alloy's `prometheus.remote_write` and `otelcol.exporter` have built-in write-ahead log (WAL) and retry. If CK is down, Alloy queues data locally and replays when CK recovers.

4. **Labels drive routing** — All containers get standard labels (`telemetry: "enabled"`, `metrics-port: "9090"`, `logs-type: "json"`). Alloy's `discovery.docker` reads these and routes accordingly.

---

## 4. Telemetry Pipelines

### 4.1 Metrics Pipeline

**Source**: Prometheus endpoints from containers + system

| Source | Endpoint | Discovery | Sample Metrics |
|--------|----------|-----------|----------------|
| All Docker containers | `container:${label metrics-port}/metrics` | `discovery.docker` + relabel | App-specific |
| PostgreSQL 14-17 | `postgres:9187/metrics` (planned) | Static target | `pg_stat_*`, query latency |
| ClickHouse | `clickhouse:8123/metrics` | Static target | `CH*` internal metrics |
| Redis | `redis:9121/metrics` (planned) | Static target | `redis_*` |
| Kafka | `kafka:9308/metrics` (planned) | Static target | `kafka_*` |
| cAdvisor (optional) | `cadvisor:8080/metrics` | Static target | Container CPU/mem/network |
| Host (via `node_exporter`) | `node_exporter:9100/metrics` | Static target | CPU, mem, disk, net |

**Processing**:

```
discovery.docker ("all_containers")
  └── prometheus.scrape (interval=15s)
       └── discovery.relabel (filter by telemetry label, add cluster_name)
            └── prometheus.remote_write
                 └── url = "http://<central-ck>:8123/prometheus/write"
```

**Relabeling rules**:

```river
discovery.relabel "add_cluster" {
  rule {
    target_label = "cluster"
    replacement  = env("CLUSTER_NAME")  // "mac-orbstack", "aliyun", "office"
  }
  rule {
    source_labels = ["__meta_docker_container_label_telemetry"]
    regex         = "enabled"
    action        = "keep"
  }
  rule {
    source_labels = ["__meta_docker_container_label_metrics_port"]
    regex         = "(.+)"
    target_label  = "__metrics_path__"
    replacement   = "/metrics"
    action        = "replace"
  }
}
```

**Metrics cardinality budget**:

| Category | Expected Series | Notes |
|----------|----------------|-------|
| Container runtime (CPU/mem/net) | ~100 / container | Via cAdvisor or Docker API |
| PostgreSQL (per instance) | ~200 | 4 PG instances, ~800 total |
| ClickHouse | ~500 | Single instance |
| Redis | ~100 | Single instance |
| Kafka (future) | ~300 | Single instance |
| cc-connect | ~50 | Hand-instrumented |
| System (node_exporter) | ~500 | Per machine |
| **Total / cluster** | **~2,500** | Comfortably within CK's capacity |
| **Total all clusters** | **~7,500** | Still trivial for CK |

### 4.2 Logs Pipeline

**Source**: Container stdout/stderr + file logs

**Two-phase approach**:

**Phase 1 (parallel run with Vector)**:
Alloy collects container logs to ClickHouse's `otel_logs` table via OTLP, alongside Vector continuing to process cc-connect logs to the `cc.message_log` table.

**Phase 2 (Vector replacement)**:
cc-connect's `slog` key=value parsing is ported from Vector's TOML transform to Alloy's `loki.process` stage blocks. Vector is decommissioned.

**Phase 2 pipeline**:

```river
// Docker container logs via Docker API
loki.source.docker "all_containers" {
  host = "unix:///var/run/docker.sock"
  targets = discovery.docker.all_containers.targets
  forward_to = [loki.process.cc_connect.receiver]
}

// Process cc-connect key=value logs
loki.process "cc_connect" {
  stage.match {
    selector = `{container_name=~"kyb-infra-cc-connect.*"}`
    stage.logfmt {
      mapping = {
        "time"         = "",
        "level"        = "",
        "msg"          = "",
        "msg_id"       = "",
        "session"      = "",
        "response_len" = "",
        "turn_duration" = "",
        "input_tokens"  = "",
        "output_tokens" = "",
      }
    }
    stage.timestamp {
      source = "time"
      format = "RFC3339Nano"
    }
  }
  
  forward_to = [loki.write.clickhouse.receiver]
}

// Write to ClickHouse via OTLP
loki.write "clickhouse" {
  endpoint = "http://<central-ck>:8123/otel/v1/logs"
}
```

> **Note**: Alloy's `loki.write` does not natively target ClickHouse HTTP. A practical intermediate is to write logs to a file and have Vector forward them, or use the OTel Collector `otlphttp` exporter from Alloy's `otelcol` blocks. This requires further prototyping.

**Alternative log path (simpler, recommended for Phase 1)**:

```
Alloy (loki.source.docker)
  └──> Loki (push API)
       └──> ClickHouse (via loki-clickhouse plugin)
```

But we don't want to run Loki just for logs. The cleaner approach is to keep Vector for logs in Phase 1 and route Alloy's log output through Vector's HTTP source:

```
Alloy (loki.source.docker ──> loki.write "vector")
  or
Alloy (otelcol ──> OTLP ──> Vector's otlp source)
```

This avoids introducing Loki as a dependency. Vector already runs and can accept OTLP logs, forwarding them to CK.

**Recommended Phase 1 log setup**:

```
Alloy collects logs ──> Vector (OTLP receiver) ──> ClickHouse
Vector continues cc-connect pipeline as before
```

### 4.3 Traces Pipeline

**Source**: OTLP from instrumented applications

**Current state**: Zero applications emit traces. This pipeline is **future-ready**, not active.

**Future pipeline**:

```river
otelcol.receiver.otlp "default" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  http {
    endpoint = "0.0.0.0:4318"
  }

  output {
    traces = [otelcol.exporter.otlphttp.clickhouse.input]
  }
}

otelcol.exporter.otlphttp "clickhouse" {
  client {
    endpoint = "http://<central-ck>:8123/otel"
  }
}
```

ClickHouse stores traces in its OpenTelemetry-native tables: `otel_spans`, `otel_span_attributes`, `otel_resources`, `otel_logs` (when the OTel exporter is configured in ClickHouse).

**Enabling OTel in ClickHouse**:

```sql
-- Enable OpenTelemetry in ClickHouse (requires server restart or setting)
SET allow_experimental_otlp_endpoint = 1;

-- The OTLP endpoint will be available at:
-- http://clickhouse:8123/otel/v1/traces
-- http://clickhouse:8123/otel/v1/logs
```

> **Note**: OTel endpoint support in ClickHouse depends on version. As of CK 23.x, the OTLP endpoint is experimental. Verify on our CK version before committing. Fallback: use `otelcol.exporter.otlphttp` to a lightweight OTel Collector that writes to CK native tables.

### 4.4 Heartbeat Replacement

**Current**: Each boss runs a `while true; curl ... INSERT INTO boss_heartbeats ...` loop.

**Replacement**: Alloy scrapes the Docker socket and system metrics, producing the same data as Prometheus metrics. The heartbeats table can be populated by a Materialized View in CK that downsamples from Prometheus metrics:

```sql
CREATE MATERIALIZED VIEW boss_heartbeats_mv
TO boss_heartbeats AS
SELECT
  cluster,
  now() AS timestamp,
  countIf(name LIKE 'kyb-infra-%' AND status = 'running') AS docker_running,
  countIf(name LIKE 'kyb-infra-%') AS docker_total,
  avg(container_last_seen_cpu_usage) AS cpu_avg
FROM prometheus_samples
WHERE __name__ IN ('container_cpu_usage_seconds_total', 'container_memory_usage_bytes')
GROUP BY cluster;
```

This replaces the heartbeat loop with real Prometheus metrics. The heartbeat table continues to exist for backwards compatibility, but is fed by Alloy metrics instead of curl.

**Migration**:
1. Deploy Alloy with Docker metrics scraping (adds `container_cpu_*`, `container_memory_*` to CK)
2. Create the MV in CK
3. After verification, stop the heartbeat curl loops on each cluster boss

---

## 5. Deployment per Cluster

### 5.1 Container Spec

Alloy runs as a Docker container on each cluster, managed by the cluster's kyb-infra-boss.

```bash
docker run -d \
  --name kyb-infra-alloy \
  --restart unless-stopped \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /proc:/host/proc:ro \
  -v /sys:/host/sys:ro \
  -v /:/host/root:ro \
  -v $(pwd)/config.alloy:/etc/alloy/config.alloy:ro \
  -e CLUSTER_NAME="mac-orbstack" \
  -e CK_ENDPOINT="http://100.104.244.99:8123" \
  grafana/alloy:latest \
    run --server.http.listen-addr=0.0.0.0:12345 /etc/alloy/config.alloy
```

**Why `--network host`**: Alloy needs to scrape local containers and system metrics. Host networking avoids Docker DNS complications and lets it reach `localhost` services.

### 5.2 kyb Integration

The boss container should manage Alloy like any other infra service:

```bash
# Create with kyb
kyb create infra-alloy --extra-mounts \
  /var/run/docker.sock:/var/run/docker.sock:ro \
  /proc:/host/proc:ro \
  /sys:/host/sys:ro

# Or run alongside the boss
docker exec kyb-infra-boss docker run -d --name kyb-infra-alloy ...
```

**Better approach**: Define a `kyb infra alloy` subcommand that:
1. Checks if Alloy is running
2. Creates it if not
3. Injects the correct `CLUSTER_NAME` and `CK_ENDPOINT` env vars
4. Verifies it's forwarding telemetry

This follows the pattern of other infra services (PG, Redis, etc.)

### 5.3 Cluster-Specific Configuration

| Cluster | CK Endpoint | CLUSTER_NAME | Extra scrape targets |
|---------|------------|--------------|---------------------|
| Mac/Orbstack | `http://localhost:8123` | `mac-orbstack` | PG x4, Redis, Kafka, ClickHouse itself |
| Aliyun (sim) | `http://100.104.244.99:8123` | `aliyun` | System only (no infra DBs on Aliyun) |
| Office (nuc8) | `http://100.104.244.99:8123` | `office` | System + local SOCKS5 metrics |

Mac's Alloy connects to `localhost:8123` (CK is on the same machine). Remote clusters connect via Tailscale to `100.104.244.99:8123`.

### 5.4 Resource Requirements

| Resource | Estimate | Notes |
|----------|----------|-------|
| CPU | 0.05-0.1 core idle, 0.3-0.5 under load | ~7,500 series scrape every 15s is negligible |
| RAM | 30-50 MB idle, ~150 MB under load | WAL buffering for CK outages |
| Disk | ~500 MB (WAL) | Configurable, in `/tmp/alloy-wal` |
| Docker socket access | Required | `ro` mount, safe |

---

## 6. Alloy Configuration

### 6.1 Full Example Config (`config.alloy`)

```river
// === Cluster Identity ===
//
// Set via environment variable per cluster:
//   CLUSTER_NAME=mac-orbstack | aliyun | office
//   CK_ENDPOINT=http://localhost:8123 | http://100.104.244.99:8123

cluster_name  = env("CLUSTER_NAME", "unknown")
ck_endpoint   = env("CK_ENDPOINT", "http://localhost:8123")

// === Logging ===
logging {
  level = "info"
  format = "logfmt"
}

// === 1. Docker Service Discovery ===

discovery.docker "all_containers" {
  host = "unix:///var/run/docker.sock"
  refresh_interval = "30s"
}

// === 2. Metrics Pipeline ===

// Scrape all containers that have telemetry="enabled" label
prometheus.scrape "docker_containers" {
  targets    = discovery.docker.all_containers.targets
  forward_to = [prometheus.relabel.filter_metrics.receiver]
  scrape_interval = "15s"

  // Default honor_labels required for Docker metrics
  honor_labels = true
}

// Filter and relabel
prometheus.relabel "filter_metrics" {
  rule {
    source_labels = ["__meta_docker_container_label_telemetry"]
    regex         = "enabled"
    action        = "keep"
  }
  rule {
    source_labels = ["__meta_docker_container_name"]
    target_label  = "container"
  }
  rule {
    target_label = "cluster"
    replacement  = cluster_name
  }
  rule {
    source_labels = ["__meta_docker_container_label_metrics_port"]
    regex         = "(.+)"
    target_label  = "__metrics_path__"
    replacement   = "/metrics"
  }

  forward_to = [prometheus.remote_write.ck.receiver]
}

// Static targets: system services
prometheus.scrape "system" {
  targets = [
    // cAdvisor (if deployed)
    // {__address__ = "localhost:8080", job = "cadvisor"},
    
    // node_exporter (if deployed)
    // {__address__ = "localhost:9100", job = "node"},
    
    // Docker Engine metrics
    {__address__ = "localhost:9323", job = "docker"},
  ]
  forward_to = [prometheus.relabel.add_cluster_system.receiver]
  scrape_interval = "30s"
}

prometheus.relabel "add_cluster_system" {
  rule {
    target_label = "cluster"
    replacement  = cluster_name
  }
  forward_to = [prometheus.remote_write.ck.receiver]
}

// Remote write to ClickHouse
prometheus.remote_write "ck" {
  endpoint {
    url = ck_endpoint + "/prometheus/write"
    
    // 60s timeout, 5s min_backoff, 30s max_backoff
    remote_timeout = "30s"
    
    queue {
      capacity           = 10000
      max_samples_per_send = 2000
      min_shards         = 2
      max_shards         = 10
    }
  }

  // WAL for durability during CK outages
  wal {
    dir = "/tmp/alloy-wal"
  }
}

// === 3. Logs Pipeline (Phase 1: forward to Vector) ===

// Discovery for Docker containers to collect logs from
discovery.docker "log_containers" {
  host = "unix:///var/run/docker.sock"
  refresh_interval = "30s"
}

// Collect container logs
loki.source.docker "all" {
  hosts       = ["unix:///var/run/docker.sock"]
  targets     = discovery.docker.log_containers.targets
  forward_to  = [loki.process.route_logs.receiver]
}

// Route to different log pipelines
loki.process "route_logs" {
  stage.static_labels {
    values = {
      cluster = cluster_name,
    }
  }

  // Route cc-connect logs specially
  stage.match {
    selector = `{container_name=~".*cc-connect.*"}`
    
    stage.logfmt {
      mapping = {
        "time"   = "",
        "level"  = "",
        "msg"    = "",
      }
    }

    forward_to = [loki.write.vector_otlp.receiver]
  }

  // All other container logs
  stage.match {
    selector = `{container_name!~".*cc-connect.*"}`
    forward_to = [loki.write.vector_otlp.receiver]
  }
}

// Send logs to Vector's OTLP receiver (runs alongside Alloy)
loki.write "vector_otlp" {
  endpoint {
    url = "http://localhost:3100/otlp/v1/logs"
    
    // Vector can accept OTLP via its `opentelemetry` source
    // For now, we use Vector's existing pipeline to forward to CK
  }
  
  // If Vector is down, buffer up to 1GB of logs
  // (configurable via WAL settings)
}

// === 4. Traces Pipeline (future, OTLP receiver) ===

// otelcol.receiver.otlp "default" {
//   grpc {
//     endpoint = "0.0.0.0:4317"
//   }
//   http {
//     endpoint = "0.0.0.0:4318"
//   }
//
//   output {
//     traces = [otelcol.exporter.otlphttp.clickhouse.input]
//   }
// }
//
// otelcol.exporter.otlphttp "clickhouse" {
//   client {
//     endpoint = ck_endpoint + "/otel"
//   }
// }

// === 5. Health Check Endpoint ===

// Alloy exposes a /metrics endpoint on :12345 by default.
// Scrape Alloy's own metrics for monitoring the collector itself.
```

### 6.2 Config Organization

For maintainability, split config into multiple files mounted from a config dir:

```
/etc/alloy/
  config.alloy          # Main entry (imports below)
  modules/
    metrics.alloy       # Metrics pipeline
    logs.alloy          # Logs pipeline  
    traces.alloy        # Traces pipeline (disabled initially)
    discovery.alloy     # Service discovery blocks
    output.alloy        # Remote write / export blocks
```

Alloy supports `import.file` for module composition:

```river
// config.alloy
import.file "metrics" {
  filename = "/etc/alloy/modules/metrics.alloy"
}
import.file "logs" {
  filename = "/etc/alloy/modules/logs.alloy"
}
```

---

## 7. ClickHouse Schemas

### 7.1 Prometheus Metrics (via remote write)

ClickHouse stores Prometheus remote-write data in the `prometheus_samples` and `prometheus_labels` tables (or equivalent). These are created by the ClickHouse Prometheus endpoint handler.

If CK version lacks built-in Prometheus tables, create manually:

```sql
-- Time-series samples table
CREATE TABLE prometheus_samples (
  date Date DEFAULT toDate(timestamp),
  timestamp DateTime64(9),
  labels String,    -- JSON-encoded label set
  name String,      -- __name__ label value
  value Float64,
  cluster String DEFAULT '',
  container String DEFAULT '',
) ENGINE = MergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (name, timestamp);

-- Downsampled aggregations (for fast dashboards)
CREATE MATERIALIZED VIEW prometheus_metrics_1m
TO prometheus_metrics_1m AS
SELECT
  name,
  labels,
  cluster,
  container,
  toStartOfMinute(timestamp) AS minute,
  avg(value) AS avg_val,
  max(value) AS max_val,
  min(value) AS min_val,
  quantile(0.5)(value) AS p50,
  quantile(0.9)(value) AS p90,
  quantile(0.99)(value) AS p99
FROM prometheus_samples
GROUP BY name, labels, cluster, container, minute;
```

**Recommended approach**: Use ClickHouse's built-in `PrometheusExporter` if available. Check:

```sql
SELECT engine FROM system.tables WHERE name = 'prometheus_samples';
```

If the table exists, CK has built-in Prometheus protocol support and the remote write will work directly.

### 7.2 OpenTelemetry Traces

```sql
-- Create OTel tables in ClickHouse (if built-in OTLP endpoint is enabled)
-- These are auto-created when the OTLP endpoint receives data,
-- or can be created manually:

CREATE TABLE otel_spans (
  TraceId String,
  SpanId String,
  ParentSpanId String,
  SpanName String,
  SpanKind String,
  StartTime DateTime64(9),
  EndTime DateTime64(9),
  StatusCode String,
  StatusMessage String,
  Attributes String,          -- JSON
  ResourceAttributes String,  -- JSON
  Cluster String DEFAULT ''
) ENGINE = MergeTree
PARTITION BY toYYYYMM(StartTime)
ORDER BY (SpanName, StartTime);

CREATE TABLE otel_span_attributes (
  TraceId String,
  SpanId String,
  Key String,
  Value String,
) ENGINE = MergeTree
ORDER BY (Key, TraceId);
```

### 7.3 Container Logs

```sql
CREATE TABLE container_logs (
  timestamp DateTime64(9),
  container_name String,
  container_id String,
  cluster String,
  log_level String DEFAULT '',
  message String,
  structured_data String DEFAULT '',  -- JSON for key=value parsed logs
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (container_name, timestamp)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

---

## 8. Grafana Data Sources & Dashboards

### 8.1 Data Source Configuration

| Data Source | Type | URL | Notes |
|-------------|------|-----|-------|
| ClickHouse (metrics) | ClickHouse | `http://clickhouse:8123` | Query `prometheus_samples` |
| ClickHouse (logs) | ClickHouse | `http://clickhouse:8123` | Query `container_logs` |
| ClickHouse (traces) | ClickHouse | `http://clickhouse:8123` | Query `otel_spans` |
| Alloy (debug) | Prometheus | `http://<cluster-host>:12345/metrics` | Alloy's self-metrics per cluster |

**Important**: Grafana needs the ClickHouse datasource plugin installed. Use `grafana/grafana:latest` with plugin pre-installed, or install via:

```bash
docker exec kyb-infra-grafana grafana-cli plugins install grafana-clickhouse-datasource
docker restart kyb-infra-grafana
```

### 8.2 Proposed Dashboards

| Dashboard | Panels | Data Source |
|-----------|--------|-------------|
| **Cluster Overview** | CPU / mem / disk per cluster (bar chart), container count, Alloy health | ClickHouse metrics |
| **Container Resource Usage** | CPU %, memory, network I/O per container, top-N by usage | ClickHouse metrics |
| **cc-connect Performance** | Message latency P50/P90/P99, token usage, error rate | ClickHouse metrics + logs |
| **Infra Services Health** | PG status, Redis latency, CK query rate, Kafka offsets | ClickHouse metrics |
| **Alloy Self-Monitoring** | Scrape duration, samples collected, WAL size, write errors | Prometheus (Alloy) |
| **Trace Explorer** | Trace list, span details, service graph (future) | ClickHouse traces |
| **Cluster Comparison** | Side-by-side CPU, mem, disk across clusters | ClickHouse metrics |

### 8.3 Dashboard as Code

Store dashboard JSON in `docs/infra/grafana-dashboards/` for version control. Export from Grafana UI or use `grafana-analytics` to programmatically generate.

---

## 9. Migration from Current Setup

### Phase 1: Deploy Alloy in Parallel (Week 1)

1. Deploy Alloy container on Mac/Orbstack (super-boss cluster)
2. Configure Docker service discovery with `telemetry="enabled"` labels on key containers
3. Add Prometheus remote-write to ClickHouse (verify data lands in `prometheus_samples`)
4. Tag a few containers: `kyb-infra-cc-connect`, `kyb-infra-postgresql-*`, `kyb-infra-kafka`, `kyb-infra-redis`
5. Build a "Container Resource Usage" dashboard in Grafana
6. Verify: metrics flow correctly, Alloy resource usage is acceptable

**Migration step: Label existing containers**

```bash
# Add telemetry labels to existing containers
docker container update --label-add telemetry=enabled --label-add metrics-port=12345 kyb-infra-alloy
docker container update --label-add telemetry=enabled kyb-infra-cc-connect
docker container update --label-add telemetry=enabled kyb-infra-postgresql-14
docker container update --label-add telemetry=enabled kyb-infra-postgresql-15
docker container update --label-add telemetry=enabled kyb-infra-postgresql-16
docker container update --label-add telemetry=enabled kyb-infra-postgresql-17
docker container update --label-add telemetry=enabled kyb-infra-kafka
docker container update --label-add telemetry=enabled kyb-infra-redis
docker container update --label-add telemetry=enabled kyb-infra-clickhouse
docker container update --label-add telemetry=enabled kyb-infra-grafana
docker container update --label-add telemetry=enabled kyb-infra-sing-box
```

### Phase 2: Add Remote Clusters (Week 1-2)

1. Deploy Alloy on Aliyun (sim) and Office (nuc8) via SSH + boss dispatch
2. Remote Alloys connect to central CK over Tailscale
3. Verify metrics arrive from all clusters
4. Build "Cluster Comparison" dashboard

### Phase 3: Logs Integration (Week 2-3)

1. Configure Alloy's `loki.source.docker` to collect container logs
2. Forward logs to Vector's OTLP receiver (Vector continues to own the CK write path)
3. Add `container_logs` table to CK
4. Verify log data appears in Grafana Explore

### Phase 4: Heartbeat Replacement (Week 3)

1. Create MV in CK that downsamples `prometheus_samples` to `boss_heartbeats` format
2. Test: query MV returns expected heartbeat data
3. One by one, stop the curl heartbeat loops on each cluster boss
4. Update Grafana heartbeat panels to use MV

### Phase 5: Vector Decommission (Week 4, optional)

1. Port cc-connect log parsing from Vector TOML to Alloy River (`loki.process` + `logfmt` parser)
2. Add Alloy's `loki.write` with ClickHouse HTTP output (or through an OTel bridge)
3. Validate: cc-connect logs in CK match Vector's output
4. Stop Vector container
5. Remove Vector from infra rotation

### Phase 6: Traces (Future)

Instrument Go services with OTel SDK:
- cc-connect: add OpenTelemetry tracing for message round-trips
- Future healthcheck / webhook services: emit traces from the start

---

## 10. Operations & Runbook

### 10.1 Deploy Alloy on a Cluster

```bash
# From the cluster boss (or via dispatch):
CLUSTER_NAME="aliyun"
CK_ENDPOINT="http://100.104.244.99:8123"

docker run -d \
  --name kyb-infra-alloy \
  --restart unless-stopped \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /etc/alloy:/etc/alloy:ro \
  -e CLUSTER_NAME="${CLUSTER_NAME}" \
  -e CK_ENDPOINT="${CK_ENDPOINT}" \
  grafana/alloy:latest \
    run --server.http.listen-addr=0.0.0.0:12345 /etc/alloy/config.alloy

# Verify
docker logs kyb-infra-alloy --tail 10
curl -s http://localhost:12345/-/healthy
```

### 10.2 Verify Metrics Flow

```bash
# Check Alloy's self-metrics
curl -s http://localhost:12345/metrics | grep alloy_scrape

# Check CK for incoming data
curl -s "http://localhost:8123?query=SELECT%20count()%20FROM%20prometheus_samples%20WHERE%20cluster%3D'${CLUSTER_NAME}'"

# Check Alloy's component health
curl -s http://localhost:12345/-/component | jq '.data[].health'
```

### 10.3 Reload Config

```bash
# Method 1: SIGHUP (graceful)
docker kill -s HUP kyb-infra-alloy

# Method 2: HTTP reload
curl -X POST http://localhost:12345/-/reload

# Method 3: Restart
docker restart kyb-infra-alloy
```

### 10.4 Troubleshooting

| Symptom | Likely Cause | Check |
|---------|-------------|-------|
| No metrics in CK | Alloy can't reach CK endpoint | `curl -s $CK_ENDPOINT/prometheus/write` |
| Container metrics missing | Docker socket not mounted or wrong path | `docker exec kyb-infra-alloy ls /var/run/docker.sock` |
| Only some containers scraped | Missing `telemetry="enabled"` label | `docker inspect <container> \| jq '.[0].Config.Labels'` |
| Alloy OOM | Too many series / high cardinality explosion | Check `alloy_prometheus_remote_storage_samples_total` metric |
| WAL filling disk | CK unreachable for extended period | `du -sh /tmp/alloy-wal`; restart if >2GB |
| High CPU | Scrape interval too aggressive | Increase `scrape_interval` from 15s to 30s |

### 10.5 Backup and Restore

Alloy has no persistent state beyond the WAL (which can be regenerated). If the Alloy container dies:

```bash
# Just recreate it
docker rm -f kyb-infra-alloy
# Re-run the deploy command above
# WAL will be empty, data will catch up on next scrape
```

### 10.6 Upgrading Alloy

```bash
# Pull new version
docker pull grafana/alloy:latest

# Recreate container
docker rm -f kyb-infra-alloy
docker run -d ... grafana/alloy:latest ...

# Verify
curl -s http://localhost:12345/-/healthy
```

---

## 11. Recommendations

### P0 — Must do before Alloy adds value

1. **[CK compatibility check]** Verify ClickHouse version supports Prometheus remote-write endpoint (`/prometheus/write`). If not, deploy a lightweight Prometheus server as an intermediary on Mac only, and use Alloy -> Prometheus -> CK.
2. **[Label strategy]** Define standard Docker labels for telemetry and apply to all existing infra containers. Without labels, Alloy cannot auto-discover scrape targets.

### P1 — Should do in Phase 1

3. **[Alloy on Mac first]** Deploy Alloy on Mac/Orbstack (where CK and Grafana already live). Validate metrics pipeline end-to-end before deploying to remote clusters.
4. **[heartbeat MV]** Create the Materialized View in CK for heartbeat replacement early. The curl loops are fragile (no backoff, no error handling, no retry).
5. **[Alloy self-monitoring dashboard]** Build a Grafana dashboard for Alloy's own health metrics. Without this, Alloy is a blind spot.

### P2 — Nice to have

6. **[Vector log forward]** In Phase 1, configure Alloy to forward Docker container logs to Vector's OTLP receiver. This gives us container logs in CK with minimal risk (Vector is already proven).
7. **[envoy config.alloy template]** Create a Jinja2 or envsubst template for `config.alloy` so that per-cluster config (CK_ENDPOINT, CLUSTER_NAME) is injected at container start without maintaining separate config files.
8. **[otel traces disabled]** Keep `otelcol.receiver.otlp` in the config but commented out. Re-enable when a service emits traces.
9. **[dashboard-as-code]** Export dashboard JSON to `docs/infra/grafana-dashboards/` from day one.

### P3 — Future

10. **[Node exporter on each cluster]** Deploy `node_exporter` on each cluster host for CPU/mem/disk metrics. Currently we only have Docker-level resource visibility. Host-level metrics (disk space, CPU temperature, network errors) require node_exporter.
11. **[cAdvisor]** Deploy cAdvisor for per-container resource metrics (CPU/mem/network). Alternative: Alloy's `discovery.docker` + `prometheus.scrape` can collect Docker Engine metrics from `localhost:9323`, which includes container resource usage without cAdvisor.
12. **[Alerts]** Set up Grafana alerting rules based on Alloy's metrics. E.g., "Alloy not reporting for >5min" -> notification.

---

## 12. Verdict

**Approved for Phase 1 implementation** with the following scope:

**Phase 1 delivers:**
- Unified metrics pipeline: Alloy scrapes all labeled containers -> CK's Prometheus endpoint -> Grafana
- Heartbeat replacement: curl loops replaced by CK Materialized View on Prometheus metrics
- Container resource dashboards: CPU, memory, network per container across all clusters
- Log forwarding: Alloy collects Docker logs and forwards to Vector (no disruption to existing pipeline)

**Phase 1 does NOT include:**
- Vector replacement (Phase 5)
- Trace collection (Phase 6)
- cAdvisor or node_exporter (P3)

**Why approve with conditions:**

Alloy solves a real problem: we have zero metrics infrastructure and zero traces. Adding a single collector that handles both (plus logs as a bonus) is the right architectural choice. The migration is low-risk because:

- Alloy runs in parallel with existing agents (Vector, heartbeat curl loops)
- Rollback is a single `docker stop` command
- Resource consumption is measurable and bounded (~50 MB RAM idle)
- The config is declarative and version-controlled

**Gate**: Verify CK's Prometheus endpoint support before deploying. If absent, Phase 1 expands to include a lightweight Prometheus server on Mac (which is still fewer agents than the status quo).

---

> **Summary**: Deploy Grafana Alloy per cluster as a unified metrics/logs/traces collector. Metrics go directly to ClickHouse's Prometheus remote-write endpoint. Logs forward to Vector (Phase 1) then migrate to Alloy-native (Phase 5). Traces are future-ready but disabled. Heartbeat curl loops are replaced by CK Materialized Views. Alloy's Docker service discovery means new containers appear in Grafana automatically when labeled.

> ／人◕ ‿‿ ◕人＼
