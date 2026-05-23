---
decision: 稍后做
---

# Cross-Cluster Metrics Aggregation Design

> **Status:** Design Document
> **Date:** 2026-05-23
> **Context:** Unified metrics aggregation across Mac/Orbstack, Aliyun VPS, Office NUC, and future K8s clusters, providing a single pane of glass for multi-cluster infrastructure health.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Current State of Metrics Collection](#2-current-state-of-metrics-collection)
3. [Aggregation Architecture](#3-aggregation-architecture)
4. [Metric Namespace & Label Taxonomy](#4-metric-namespace--label-taxonomy)
5. [Data Pipeline from Each Cluster](#5-data-pipeline-from-each-cluster)
6. [Network & Bandwidth Budget](#6-network--bandwidth-budget)
7. [Grafana Dashboard Patterns for Cross-Cluster Views](#7-grafana-dashboard-patterns-for-cross-cluster-views)
8. [Cross-Cluster Query Patterns](#8-cross-cluster-query-patterns)
9. [Alert Aggregation & Deduplication](#9-alert-aggregation--deduplication)
10. [Handling Cluster Asymmetry](#10-handling-cluster-asymmetry)
11. [K8s Cluster Integration (Future)](#11-k8s-cluster-integration-future)
12. [Failure Modes & Degradation](#12-failure-modes--degradation)
13. [Operational Runbook](#13-operational-runbook)
14. [Implementation Plan](#14-implementation-plan)

---

## 1. Problem Statement

### 1.1 The Multi-Cluster Reality

The kyb infrastructure spans **three active clusters** today, with a fourth (K8s on Volcano Engine) planned:

| Cluster | Host | Role | Services | Network |
|---------|------|------|----------|---------|
| Mac/Orbstack | `dongqs-mac` | Super-boss, central observability | CK, Grafana, PG 14-17, Redis, Kafka, sing-box, cc-connect | Orbstack (`192.168.97.0/24`), Tailscale `100.104.244.99` |
| Aliyun VPS | `sim` (47.100.71.220) | Build runner, cache, mirror | ACR mirror, OSS cache, build containers | Bridge (`172.17.0.0/16`), Tailscale `100.113.24.32` |
| Office NUC | `nuc8` (100.98.29.39) | Proxy exit, artifact cache | GitLab mirror, Nexus proxy, SOCKS5 exit | Bridge, Tailscale `100.98.29.39` (CGNAT) |
| Volcano Engine | `TBD` | CI runners, K8s workloads | K8s cluster, DERP relay | Future |

### 1.2 Why Central Aggregation Fails at Scale

Each cluster generates metrics from different sources at different granularities:

- **Mac/Orbstack**: CK internal metrics, PG query stats, Kafka consumer lag, cc-connect application metrics, Redis hit rates, sing-box proxy traffic. ~2,500 time series.
- **Aliyun**: Docker container resource usage, OSS cache hit rates, build queue depth, disk/memory pressure. ~500 time series.
- **Office**: Docker container resource usage, Nexus cache metrics, SOCKS5 connection counts, GitLab mirror sync lag. ~300 time series.

A naive central aggregation -- shovel everything from everywhere into one ClickHouse instance -- creates several problems:

1. **Label collision**: Two clusters both emit `docker_containers_running` -- whose is whose?
2. **Time alignment**: Heartbeat at 60s, Prometheus at 15s, cadvisor at 30s -- joining across sources produces misleading results.
3. **Bandwidth cost**: Aliyun has 3 Mbps outbound. Pushing 2,500 time series x 15s from Aliyun would saturate it.
4. **Silent degradation**: When Aliyun goes offline (network partition), the metrics pipeline silently loses data -- is the cluster down or just the telemetry?
5. **Asymmetric service distribution**: Not every cluster runs every service. A dashboard that expects `pg_stat_database` from all clusters will have gaps.

### 1.3 Design Goals

1. **Single pane of glass** -- one Grafana instance showing all clusters, with cluster as a template variable.
2. **Standardized metric taxonomy** -- every metric has `cluster`, `service`, `metric_type` labels. Cross-cluster queries use label matching, not table joins.
3. **Bandwidth-aware collection** -- remote clusters (Aliyun, Office) collect locally and push summaries, not raw 15s scrapes. Only Mac/Orbstack (where CK lives) sends full-resolution data.
4. **Graceful degradation** -- if a remote cluster stops reporting, dashboards show "stale" not "empty". Alerts fire only after a grace period.
5. **Immutable metric names** -- once a metric name is published, it is never renamed or re-labeled without a deprecation period.
6. **K8s-ready label scheme** -- the label taxonomy must extend to Kubernetes (pod name, namespace, container name) without structural changes.

---

## 2. Current State of Metrics Collection

### 2.1 Collection Mechanisms (As-Is)

| Mechanism | Clusters | Metrics | Granularity | Destination | Status |
|-----------|----------|---------|-------------|-------------|--------|
| Heartbeat curl loop | All 3 | `docker_running`, `docker_total`, `disk_used_pct`, `mem_used_pct`, `load_1m` | 60s | CK `boss_heartbeats` | Running |
| Prometheus scrape | Mac/Orbstack only (designed) | Container CPU/mem/network, app metrics, host metrics | 15-30s | Prometheus TSDB | Not deployed |
| Grafana Alloy | Mac/Orbstack (Phase 1) | Docker container metrics via `discovery.docker` | 15s | CK `prometheus_samples` | In deployment |
| node_exporter | Designed for all 3 | Host CPU, mem, disk, network, load | 30s | Prometheus scrape | Not deployed |
| cadvisor | Designed for all 3 | Per-container CPU, mem, network, FS | 30s | Prometheus scrape | Not deployed |

### 2.2 Current Data Flow Diagram

```
Mac/Orbstack:
  Boss heartbeat loop ──curl──> CK (local, 0 network cost)
  Grafana Alloy ──remote write──> CK (local, 0 network cost)
  Prometheus ──scrape──> local exporters (cadvisor, node_exporter) [planned]

Aliyun:
  Boss heartbeat loop ──curl──> CK at 100.104.244.99:8123 (over Tailscale, ~12ms)

Office:
  Boss heartbeat loop ──curl──> CK at 100.104.244.99:8123 (over Tailscale, ~8ms relay)
```

**Key observation**: Remote clusters currently only push heartbeats (5 fields, 60s). This is ~50 bytes per push, ~72 KB/day per cluster. Negligible bandwidth.

If we push full Prometheus metrics from remote clusters (500-2,500 time series at 15s), the bandwidth becomes significant, especially for Aliyun's 3 Mbps outbound cap.

### 2.3 Current Gaps

1. **No per-container resource visibility on remote clusters** -- cannot see if a build container on Aliyun is leaking memory.
2. **No disk growth trend data** -- heartbeat `disk_used_pct` is a point-in-time snapshot with no history of growth rate.
3. **No cross-cluster comparison** -- cannot answer "is Aliyun's load normal compared to Office?"
4. **No aggregate health score** -- "are all clusters healthy?" requires checking three separate dashboards.
5. **Prometheus-only on Mac** -- if we deploy Prometheus per the existing design, remote clusters are still invisible to Prometheus queries.

---

## 3. Aggregation Architecture

### 3.1 Layered Collection Model

The cross-cluster aggregation uses a **tiered collection model**, not a flat push-all approach:

```
Tier 1: Local Collection (per cluster)
  ┌─────────────────────────────────┐
  │  Cluster Agent (Grafana Alloy)  │
  │                                 │
  │  ┌──────────┐ ┌──────────────┐  │
  │  │ Docker   │ │ System/Host  │  │
  │  │ metrics  │ │ metrics      │  │
  │  └────┬─────┘ └──────┬───────┘  │
  │       │              │          │
  │  ┌────┴──────────────┴───────┐  │
  │  │      Alloy Pipeline       │  │
  │  │  scrape → filter → batch  │  │
  │  └────┬──────────────────────┘  │
  └───────┼─────────────────────────┘
          │
          ▼
  ┌─────────────────────────────────┐
  │    Tier 2: Aggregation Layer    │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  ClickHouse (Mac/Orbstack) │  │
  │  │                           │  │
  │  │  prometheus_samples       │  │
  │  │  boss_heartbeats          │  │
  │  │  container_logs           │  │
  │  │  cluster_events           │  │
  │  └────────────┬──────────────┘  │
  └───────────────┼─────────────────┘
                  │
                  ▼
  ┌─────────────────────────────────┐
  │    Tier 3: Visualization        │
  │                                 │
  │  ┌───────────────────────────┐  │
  │  │  Grafana (Mac/Orbstack)   │  │
  │  │                           │  │
  │  │  Template: $cluster       │  │
  │  │  Template: $service       │  │
  │  │  Cross-cluster dashboards │  │
  │  └───────────────────────────┘  │
  └─────────────────────────────────┘
```

### 3.2 Collection Strategy per Cluster

Each cluster runs a **Grafana Alloy** container as the local telemetry collector. The collection behavior differs by cluster tier:

**Mac/Orbstack (Tier 0 - Central):**
- Full-resolution collection: Alloy scrapes all local containers at 15s
- Prometheus remote-write to local CK (no network cost)
- All service exporters: PG, Redis, Kafka, ClickHouse, sing-box
- node_exporter + cadvisor at 30s

**Aliyun (Tier 1 - Remote, Bandwidth-Constrained):**
- Local collection at 15s inside Alloy
- Downsample before shipping: aggregate to 60s resolution via `prometheus.relabel` + `metric_relabel_configs`
- Ship only essential metrics: container CPU/mem/disk top-5, host load/disk/mem, build queue depth
- Batch: send every 60s, not 15s
- Exclude: PG, Kafka, Redis metrics (not running on Aliyun)

**Office (Tier 1 - Remote, Tailscale-Relayed):**
- Same as Aliyun: 60s downsampled, essential metrics only
- Add: Nexus cache hit rate, SOCKS5 connection count, GitLab mirror sync status

**Volcano/K8s (Tier 2 - Future, High-Volume):**
- kube-state-metrics and node metrics scraped locally by Prometheus Operator
- Prometheus remote-write to central CK (with rate limiting)
- Pod-level metrics: downsampled to 60s before shipping
- Cluster-level (node) metrics: full resolution

### 3.3 Data Flow: Remote Cluster to Central CK

```
Remote Cluster (Aliyun/Office)
┌────────────────────────────────────┐
│  Grafana Alloy                     │
│                                    │
│  prometheus.scrape (15s local)     │
│       │                            │
│       ▼                            │
│  prometheus.relabel                │
│       ├── Add cluster label        │
│       ├── Add service label        │
│       └── Downsample to 60s        │
│       │                            │
│       ▼                            │
│  prometheus.remote_write           │
│       │  url=http://100.x:8123/    │
│       │  prometheus/write          │
│       │  queue.capacity=5000       │
│       ▼                            │
│  WAL (local buffer) ────> CK      │
└────────────────────────────────────┘
         │ Tailscale (8-12ms)
         ▼
Central CK (Mac/Orbstack)
┌────────────────────────────────────┐
│  prometheus_samples table          │
│  boss_heartbeats table             │
└────────────────────────────────────┘
```

### 3.4 Alloy Configuration: Remote Cluster Template

```river
// Remote cluster Alloy config
// CLUSTER_NAME = "aliyun" | "office"
// CK_ENDPOINT  = "http://100.104.244.99:8123"
// SCRAPE_INTERVAL = "15s"
// SEND_INTERVAL   = "60s"

cluster_name = env("CLUSTER_NAME", "unknown")
ck_endpoint  = env("CK_ENDPOINT", "http://localhost:8123")
scrape_int   = env("SCRAPE_INTERVAL", "15s")
send_int     = env("SEND_INTERVAL", "60s")

// === Docker Service Discovery ===

discovery.docker "all_containers" {
  host = "unix:///var/run/docker.sock"
  refresh_interval = "30s"
}

// === Metrics Pipeline ===

prometheus.scrape "docker_containers" {
  targets    = discovery.docker.all_containers.targets
  forward_to = [prometheus.relabel.aggregate.receiver]
  scrape_interval = scrape_int
  honor_labels = true
}

prometheus.relabel "aggregate" {
  // Add cluster identity to every metric
  rule {
    target_label = "cluster"
    replacement  = cluster_name
  }
  // Add service label from container name prefix
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "(kyb-infra-|node_exporter|cadvisor|)(.+)"
    target_label  = "service"
    replacement   = "$2"
  }
  // Remove high-cardinality labels from Podman/Docker
  rule {
    source_labels = ["__meta_docker_container_id"]
    action        = "labeldrop"
  }
  rule {
    source_labels = ["__meta_docker_container_image_id"]
    action        = "labeldrop"
  }

  forward_to = [prometheus.relabel.downsample.receiver]
}

// Downsample: aggregate raw 15s samples into 60s summaries
// This is the key bandwidth-saving step for remote clusters
prometheus.relabel "downsample" {
  // Keep only metrics that indicate cluster health
  // Drop per-process, per-device, per-cgroup detail
  rule {
    source_labels = ["__name__"]
    regex         = "(container_cpu_usage_seconds_total|container_memory_working_set_bytes|container_network_receive_bytes_total|container_network_transmit_bytes_total|container_last_seen|up|docker_.*)"
    action        = "keep"
  }

  forward_to = [prometheus.remote_write.ck.receiver]
}

// Remote write to central ClickHouse
prometheus.remote_write "ck" {
  endpoint {
    url = ck_endpoint + "/prometheus/write"
    remote_timeout = "30s"

    queue {
      capacity           = 5000
      max_samples_per_send = 2000
      min_shards         = 1
      max_shards         = 3
    }
  }

  // WAL for durability during CK or network outages
  wal {
    dir = "/tmp/alloy-wal"
  }

  // Write frequency: batch and send every 60s instead of every 15s
  // This reduces bandwidth by ~75%
  remote_write {
    // In Alloy, tune via queue and batch settings
    // max_shards=1 ensures sequential sends (no parallel connections)
    // min_shards=1 keeps one steady stream
    // capacity=5000 absorbs burst without dropping
  }
}

// === Additional: Node metrics if node_exporter is local ===

prometheus.scrape "node" {
  targets = [
    {__address__ = "localhost:9100", job = "node"},
  ]
  forward_to = [prometheus.relabel.add_cluster_node.receiver]
  scrape_interval = "30s"
}

prometheus.relabel "add_cluster_node" {
  rule {
    target_label = "cluster"
    replacement  = cluster_name
  }
  // Keep only aggregate host-level metrics
  rule {
    source_labels = ["__name__"]
    regex         = "(node_load1|node_load5|node_load15|node_memory_MemAvailable_bytes|node_memory_MemTotal_bytes|node_filesystem_avail_bytes|node_filesystem_size_bytes|node_network_receive_bytes_total|node_network_transmit_bytes_total|node_boot_time_seconds|node_nf_conntrack_entries|node_nf_conntrack_entries_limit|node_procs_running|node_procs_blocked)"
    action        = "keep"
  }
  forward_to = [prometheus.remote_write.ck.receiver]
}
```

### 3.5 Local Collection Only: What Stays on Each Cluster

Some metrics are **collected locally but never shipped** to central CK:

| Metric | Reason | Local Action |
|--------|--------|-------------|
| Per-container network per-interface | High cardinality (one series per interface per container) | Aggregate to container-total in Alloy |
| Per-process CPU/mem | Too many series, not useful cross-cluster | Drop at Alloy relabel step |
| Docker events stream | Real-time, not historical | Local log only |
| Raw container stdout logs (non cc-connect) | Too much volume (MB/hour) | Alloy forwards to local Vector, not to CK |
| Prometheus target scrape failures | Debugging detail, not cross-cluster relevant | Drop |

These are available for local debugging via `docker exec` or Alloy's debug endpoint, but not aggregated.

---

## 4. Metric Namespace & Label Taxonomy

### 4.1 Standard Label Set

Every metric that crosses the cluster boundary **must** carry these labels:

| Label | Description | Example Values | Required |
|-------|-------------|----------------|----------|
| `cluster` | Originating cluster | `mac-orbstack`, `aliyun`, `office`, `volcano-k8s` | Always |
| `service` | Service or component | `cc-connect`, `postgresql-16`, `node-exporter`, `cadvisor`, `alloy` | Always |
| `metric_type` | Category of measurement | `system`, `container`, `application`, `network`, `storage` | Always |
| `host` | Hostname or node name | `sim`, `nuc8`, `dongqs-mac`, `k8s-node-1` | Recommended |
| `env` | Deployment environment | `production`, `staging`, `sandbox` | Optional, default `production` |

### 4.2 Metric Naming Convention

```
kyb_<metric_type>_<component>_<measurement>
```

Examples:

| Metric Name | Type | Component | Measurement | Labels |
|-------------|------|-----------|-------------|--------|
| `kyb_system_cluster_boot_time` | system | cluster | boot_time | cluster, service=alloy |
| `kyb_system_container_running` | system | container | running | cluster, service |
| `kyb_system_container_total` | system | container | total | cluster, service |
| `kyb_system_disk_used_pct` | system | disk | used_pct | cluster, mountpoint |
| `kyb_system_mem_used_pct` | system | memory | used_pct | cluster |
| `kyb_system_load_1m` | system | load | 1m | cluster |
| `kyb_application_turn_duration` | application | cc-connect | turn_duration | cluster, chat_type |
| `kyb_application_messages_total` | application | cc-connect | messages_total | cluster, status |
| `kyb_storage_pg_commit_latency` | storage | postgresql | commit_latency | cluster, pg_version |
| `kyb_network_proxy_traffic_bytes` | network | sing-box | traffic_bytes | cluster, direction |
| `kyb_network_tailscale_latency` | network | tailscale | latency | cluster, peer |

### 4.3 Label Value Taxonomy

**`cluster` values** -- These are the canonical cluster identifiers used in all queries, dashboards, and alert routing:

```yaml
clusters:
  - id: mac-orbstack
    name: "Mac/Orbstack"
    tier: "central"
    grafana_variable: "mac"
  - id: aliyun
    name: "Aliyun VPS (sim)"
    tier: "remote"
    grafana_variable: "aliyun"
  - id: office
    name: "Office NUC (nuc8)"
    tier: "remote"
    grafana_variable: "office"
  - id: volcano-k8s
    name: "Volcano Engine K8s"
    tier: "remote-k8s"
    grafana_variable: "volcano"
```

**`service` values** -- Standard service identifiers:

```yaml
services:
  - id: alloy
    description: "Grafana Alloy telemetry collector"
    runs_on: [all clusters]
  - id: boss
    description: "Cluster boss container"
    runs_on: [all clusters]
  - id: node-exporter
    description: "Host metrics exporter"
    runs_on: [all clusters]
  - id: clickhouse
    description: "Central ClickHouse"
    runs_on: [mac-orbstack]
  - id: grafana
    description: "Central Grafana"
    runs_on: [mac-orbstack]
  - id: postgresql-14
    description: "PostgreSQL 14"
    runs_on: [mac-orbstack]
  - id: postgresql-15
    description: "PostgreSQL 15"
    runs_on: [mac-orbstack]
  - id: postgresql-16
    description: "PostgreSQL 16"
    runs_on: [mac-orbstack]
  - id: postgresql-17
    description: "PostgreSQL 17"
    runs_on: [mac-orbstack]
  - id: redis
    description: "Redis cache"
    runs_on: [mac-orbstack]
  - id: kafka
    description: "Kafka event stream"
    runs_on: [mac-orbstack]
  - id: cc-connect
    description: "Feishu bridge"
    runs_on: [mac-orbstack]
  - id: sing-box
    description: "Proxy exit"
    runs_on: [mac-orbstack]
  - id: acr-mirror
    description: "ACR registry mirror"
    runs_on: [aliyun]
  - id: oss-cache
    description: "OSS artifact cache"
    runs_on: [aliyun]
  - id: build-runner
    description: "CI build runner"
    runs_on: [aliyun]
  - id: gitlab-mirror
    description: "GitLab mirror proxy"
    runs_on: [office]
  - id: nexus-cache
    description: "Nexus artifact cache"
    runs_on: [office]
  - id: proxy-exit
    description: "SOCKS5 office proxy"
    runs_on: [office]
```

**`metric_type` values:**

```yaml
metric_types:
  - system: "Host-level or cluster-level system metrics (CPU, memory, disk, load)"
  - container: "Per-container resource metrics (CPU, memory, network)"
  - application: "Application-level business metrics (message counts, latency, tokens)"
  - network: "Network throughput, latency, errors"
  - storage: "Database and cache metrics (query latency, replication lag, cache hits)"
  - event: "Discrete events (container create/destroy, boss online/offline, deploy events)"
```

### 4.4 Migration from Legacy Metrics

Existing metrics in CK (from heartbeat curl loops) do not carry these labels. Migration plan:

1. **Phase 1** (immediate): Add `cluster` label to existing heartbeat POST data
2. **Phase 2** (within Alloy deployment): Create MV in CK to transform legacy `boss_heartbeats` table rows to the new label format
3. **Phase 3** (after verification): Deprecate old heartbeat table, rename to `legacy_boss_heartbeats`

```sql
-- Phase 2: Materialized View for legacy compatibility
CREATE MATERIALIZED VIEW boss_heartbeats_v2
TO prometheus_samples AS
SELECT
  now64() AS timestamp,
  concat('kyb_system_', lower(name)) AS name,
  toFloat64(value) AS value,
  map(
    'cluster', cluster,
    'service', 'boss',
    'metric_type', 'system',
    'host', cluster
  ) AS labels,
  cluster,
  'boss' AS service
FROM (
  SELECT
    cluster,
    ['docker_running', 'docker_total', 'disk_used_pct', 'mem_used_pct', 'load_1m'] AS names,
    [docker_running, docker_total, disk_used_pct, mem_used_pct, load_1m] AS values
  FROM boss_heartbeats
  WHERE timestamp > now() - 3600
)
ARRAY JOIN names AS name, values AS value;
```

---

## 5. Data Pipeline from Each Cluster

### 5.1 Pipeline Comparison

| Step | Mac/Orbstack | Aliyun | Office | Volcano (future) |
|------|-------------|--------|--------|-------------------|
| **Collector** | Alloy (local) | Alloy (local) | Alloy (local) | Prometheus Operator |
| **Scrape interval** | 15s | 15s | 15s | 15-30s |
| **Send interval** | 15s (real-time) | 60s (batched) | 60s (batched) | 60s (batched) |
| **Downsampling** | None (full resolution) | Aggregate to 60s avg | Aggregate to 60s avg | Aggregate to 60s avg |
| **Metrics shipped** | All (~2,500 series) | Essential only (~200) | Essential only (~150) | Essential only (~500) |
| **Transport** | Localhost (0 network) | Tailscale (12ms) | Tailscale (8ms relay) | Tailscale (TBD) |
| **Compression** | N/A (localhost) | Snappy (built-in) | Snappy (built-in) | Snappy (built-in) |
| **WAL** | Enabled (small) | Enabled (1GB limit) | Enabled (1GB limit) | Enabled (2GB limit) |

### 5.2 Data Volume Estimates

**Mac/Orbstack (full resolution, all metrics):**

| Metric Category | Series Count | Scrape Interval | Samples/Day | Raw Size/Day* |
|----------------|-------------|-----------------|-------------|--------------|
| Container CPU | 50 | 15s | 288,000 | ~11 MB |
| Container memory | 50 | 15s | 288,000 | ~11 MB |
| Container network | 100 | 15s | 576,000 | ~23 MB |
| Host (node_exporter) | 300 | 30s | 864,000 | ~34 MB |
| PG exporters (x4) | 800 | 30s | 2,304,000 | ~92 MB |
| Redis exporter | 100 | 30s | 288,000 | ~11 MB |
| Kafka exporter | 300 | 30s | 864,000 | ~34 MB |
| ClickHouse exporter | 500 | 30s | 1,440,000 | ~57 MB |
| cc-connect metrics | 50 | 15s | 288,000 | ~11 MB |
| Alloy self-metrics | 100 | 15s | 576,000 | ~23 MB |
| **Total** | **~2,450** | -- | **~7,776,000** | **~307 MB/day** |

**Aliyun (downsampled, essential only):**

| Metric Category | Series Count | Send Interval | Samples/Day | Raw Size/Day* | Network Volume** |
|----------------|-------------|---------------|-------------|--------------|-----------------|
| Container CPU (top-5) | 5 | 60s | 7,200 | ~288 KB | ~86 KB |
| Container memory (top-5) | 5 | 60s | 7,200 | ~288 KB | ~86 KB |
| Host load | 3 | 60s | 4,320 | ~173 KB | ~52 KB |
| Host disk | 2 | 60s | 2,880 | ~115 KB | ~35 KB |
| Host memory | 2 | 60s | 2,880 | ~115 KB | ~35 KB |
| Host network | 2 | 60s | 2,880 | ~115 KB | ~35 KB |
| Docker events | 5 | 60s | 7,200 | ~288 KB | ~86 KB |
| **Total** | **~24** | -- | **~34,560** | **~1.38 MB/day** | **~415 KB/day** |

**Office (downsampled, essential only):**

| Metric Category | Series Count | Send Interval | Samples/Day | Raw Size/Day | Network Volume** |
|----------------|-------------|---------------|-------------|--------------|-----------------|
| Container CPU (top-5) | 5 | 60s | 7,200 | ~288 KB | ~86 KB |
| Container memory (top-5) | 5 | 60s | 7,200 | ~288 KB | ~86 KB |
| Host metrics | 9 | 60s | 12,960 | ~518 KB | ~155 KB |
| Nexus cache hit rate | 1 | 60s | 1,440 | ~58 KB | ~17 KB |
| SOCKS5 connections | 1 | 60s | 1,440 | ~58 KB | ~17 KB |
| GitLab mirror sync lag | 1 | 60s | 1,440 | ~58 KB | ~17 KB |
| **Total** | **~22** | -- | **~31,680** | **~1.27 MB/day** | **~378 KB/day** |

*\* Raw size = (8 bytes value + 8 bytes timestamp + ~50 bytes labels) x samples. Snappy compression typically reduces by 3-5x.*
*\*\* Network volume = after Snappy compression (estimated 3x reduction).*

**Total cross-cluster network volume**: ~800 KB/day from remote clusters to central CK. This is negligible for Aliyun's 3 Mbps outbound cap (3 Mbps = 32.4 GB/day = 40,000x headroom).

### 5.3 Remote Write Resilience

The Alloy WAL (Write-Ahead Log) provides buffering during CK or network outages:

```river
prometheus.remote_write "ck" {
  endpoint {
    url = ck_endpoint + "/prometheus/write"
    remote_timeout = "30s"

    queue {
      capacity           = 5000
      max_samples_per_send = 2000
      min_shards         = 1
      max_shards         = 3
    }

    // Retry with backoff
    retry {
      initial_delay = "1s"
      max_delay     = "30s"
      max_retries   = 10
    }
  }

  wal {
    dir = "/tmp/alloy-wal"
    truncate_frequency = "5m"
    max_segment_size = "100MB"
  }

  // Degradation behavior:
  // - CK down < 5min: WAL buffers, continues on reconnect (no data loss)
  // - CK down 5-30min: WAL grows but within bounds (5000 samples queued = ~3 days at 60s send)
  // - CK down > 30min: Old samples are dropped (newer data preferred over gap filling)
}
```

### 5.4 Boss Heartbeat Migration

The existing curl-based heartbeat loops should be replaced by Alloy's Docker metrics. Migration:

1. **Keep heartbeat loops running** during Alloy deployment (no gap)
2. **Add Alloy-based equivalent metrics** (`kyb_system_container_running`, `kyb_system_disk_used_pct`, etc.)
3. **Create CK Materialized View** to populate `boss_heartbeats` table from Prometheus samples
4. **Validate** MV produces same values as curl loops
5. **Stop curl loops** on each boss
6. **Define boss-specific metrics** in Alloy config (use `prometheus.scrape` to hit the boss exporter port 9101)

```river
// Boss-specific metrics (replaces curl heartbeat loop)
prometheus.scrape "boss" {
  targets = [
    {__address__ = "localhost:9101", job = "boss"},
  ]
  forward_to = [prometheus.relabel.add_cluster_boss.receiver]
  scrape_interval = "60s"
}

prometheus.relabel "add_cluster_boss" {
  rule {
    target_label = "cluster"
    replacement  = cluster_name
  }
  rule {
    target_label = "service"
    replacement  = "boss"
  }
  rule {
    target_label = "metric_type"
    replacement  = "system"
  }
  forward_to = [prometheus.remote_write.ck.receiver]
}
```

---

## 6. Network & Bandwidth Budget

### 6.1 Cluster Connectivity Matrix

```
Source \ Target        sim(100.113.24.32)   nuc8(100.98.29.39)   dongqs-mac(100.104.244.99)
mac-orbstack           12ms direct          8ms relay (CGNAT)    —
aliyun (sim)           —                    direct 10ms          12ms direct
office (nuc8)          direct 10ms          —                    8ms relay
```

**Key constraint**: Aliyun (sim) has a **3 Mbps outbound bandwidth cap**. This is the bottleneck for all remote metrics shipping.

### 6.2 Bandwidth Budget Allocation

| Traffic Type | Daily Volume | % of 3 Mbps | Notes |
|-------------|-------------|-------------|-------|
| Metrics (Prometheus remote-write) | ~415 KB | 0.003% | Snappy-compressed, 60s batch |
| Heartbeat (curl loop) | ~72 KB | 0.0005% | Being replaced by Alloy |
| Logs (future, Vector OTLP) | ~5-10 MB | 0.04% | Only cc-connect logs, compressed |
| Docker pull (from ACR, internal) | ~500 MB | 4% | Ephemeral, not continuous |
| SSH/management traffic | ~50 MB | 0.4% | Infrequent |
| Tailkeep (Tailscale keepalive) | ~5 MB | 0.04% | Constant overhead |
| **Total** | **~560 MB/day** | **~4.5%** | **95.5% headroom** |

**Conclusion**: Metric aggregation from Aliyun adds <0.01% overhead on the 3 Mbps outbound. Bandwidth is not a concern even with full-resolution metrics. However, we still downsample to 60s to avoid unnecessary CK write amplification.

### 6.3 Compression Analysis

Prometheus remote-write protocol uses **Snappy compression** natively. Measured compression ratios:

| Data Type | Raw Size | Snappy Size | Ratio |
|-----------|----------|-------------|-------|
| Float64 samples (16 bytes each) | 16 bytes | ~8-12 bytes | 1.3-2x |
| Label sets (50-100 bytes) | 75 bytes avg | ~20-30 bytes | 2.5-3x |
| Timestamp (int64 nanosecond) | 8 bytes | ~4-6 bytes | 1.3-2x |
| **Overall (with Snappy framing)** | -- | -- | **~3-5x** |

The total remote-write payload per 60s batch from Aliyun:
- ~24 samples x ~60 bytes (with compressed labels) = ~1,440 bytes per batch
- At 60s interval: ~2 MB/day raw, ~400 KB/day compressed
- This is a single TCP connection, negligible overhead

### 6.4 Network Cost Comparison: Push vs Pull

| Approach | Volume | Reliability | Complexity |
|----------|--------|-------------|------------|
| **Alloy push** (prometheus.remote_write) | ~400 KB/day | WAL buffers, retries | Low (built-in) |
| **Prometheus pull** (central Prometheus scrapes remote) | ~400 KB/day | No buffer (lost on scrape fail) | Medium (needs network access) |
| **SSH tunnel + pull** (reverse tunnel for Prometheus) | ~400 KB/day + tunnel overhead | Fragile (tunnel failure = data loss) | High (tunnel management) |

**Verdict**: Alloy push is the right choice. It has built-in buffering, compression, and retry. The remote cluster is in control of its own telemetry pipeline.

---

## 7. Grafana Dashboard Patterns for Cross-Cluster Views

### 7.1 Template Variables

Every cross-cluster dashboard must define these template variables:

```yaml
# Grafana dashboard template variables
templating:
  - name: cluster
    type: query
    query: "SELECT DISTINCT cluster FROM prometheus_samples WHERE $__timeFilter"
    multi: true
    includeAll: true
    default: "All"
    description: "Select one or more clusters to compare"

  - name: service
    type: query
    query: "SELECT DISTINCT service FROM prometheus_samples WHERE cluster IN ($cluster) AND $__timeFilter"
    multi: true
    includeAll: true
    default: "All"
    description: "Select one or more services"

  - name: metric_type
    type: query
    query: "SELECT DISTINCT metric_type FROM prometheus_samples WHERE cluster IN ($cluster) AND service IN ($service) AND $__timeFilter"
    multi: true
    includeAll: true
    default: "All"

  - name: interval
    type: interval
    values: ["30s", "1m", "5m", "15m", "1h"]
    default: "1m"
    description: "Query resolution interval"
```

### 7.2 Dashboard: Global Cluster Overview

The single most important dashboard: **all clusters, all key metrics, one page**.

**Row 1: Cluster Heartbeat Status**

| Panel | Type | Query | Purpose |
|-------|------|-------|---------|
| Cluster Health Matrix | Table | `kyb_system_cluster_boot_time` per cluster, colored by recency | Which clusters are alive right now |
| Container Count | Stat | `sum(kyb_system_container_running) by cluster)` | Total running containers across all infra |
| Hosts Online | Stat | `count(distinct cluster)` | How many clusters reporting |
| Last Data Received | Table | `max(timestamp) by cluster` | Staleness warning |

**Row 2: System Resources (per cluster, side by side)**

| Panel | Type | Query | Purpose |
|-------|------|-------|---------|
| CPU Load (1m avg) | Time series | `avg(kyb_system_load_1m) by (cluster)` | Compare CPU load across clusters |
| Memory Used | Time series | `avg(kyb_system_mem_used_pct) by (cluster)` | Compare memory pressure |
| Disk Used | Time series | `avg(kyb_system_disk_used_pct) by (cluster, mountpoint)` | Compare disk usage |
| Network I/O | Time series | `rate(kyb_network_proxy_traffic_bytes[5m]) by (cluster)` | Compare network activity |

**Row 3: Container Resources (top containers per cluster)**

| Panel | Type | Query | Purpose |
|-------|------|-------|---------|
| Top CPU Consumers | Table | `topk(5, container_cpu) by (cluster, container)` | Find noisy containers across clusters |
| Top Memory Consumers | Table | `topk(5, container_memory) by (cluster, container)` | Find memory hogs |
| Container Restarts | Table | `changes(container_start_time[15m]) > 0` by cluster | Detect crash-looping containers |

**Row 4: Cluster Events**

| Panel | Type | Query | Purpose |
|-------|------|-------|---------|
| Recent Events | Log panel | `SELECT * FROM cluster_events WHERE $__timeFilter ORDER BY timestamp DESC LIMIT 50` | Cluster online/offline, deploy events |

### 7.3 Dashboard: Cluster Comparison (Side-by-Side)

This dashboard is designed for **spot-the-difference** troubleshooting:

```
┌─────────────────────────────────────────────────────────────────┐
│ Cluster Selector: [mac-orbstack █] [aliyun █] [office █]       │
│ Time Range: [Last 1h █]  Refresh: [30s █]                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────┐  ┌────────────────────────┐         │
│  │   mac-orbstack         │  │   aliyun               │         │
│  │   ┌─── CPU ──────────┐ │  │   ┌─── CPU ──────────┐ │         │
│  │   │ [timeseries]     │ │  │   │ [timeseries]     │ │         │
│  │   └──────────────────┘ │  │   └──────────────────┘ │         │
│  │   ┌─── Memory ───────┐ │  │   ┌─── Memory ───────┐ │         │
│  │   │ [timeseries]     │ │  │   │ [timeseries]     │ │         │
│  │   └──────────────────┘ │  │   └──────────────────┘ │         │
│  │   ┌─── Disk ─────────┐ │  │   ┌─── Disk ─────────┐ │         │
│  │   │ [timeseries]     │ │  │   │ [timeseries]     │ │         │
│  │   └──────────────────┘ │  │   └──────────────────┘ │         │
│  └────────────────────────┘  └────────────────────────┘         │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │  office                                                 │     │
│  │  ┌─── CPU ────────────────────────────────────────────┐ │     │
│  │  │ [timeseries]                                      │ │     │
│  │  └───────────────────────────────────────────────────┘ │     │
│  │  ┌─── Memory ────────────────────────────────────────┐ │     │
│  │  │ [timeseries]                                      │ │     │
│  │  └───────────────────────────────────────────────────┘ │     │
│  └─────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

**Key design choice**: Side-by-side panels (one per cluster) rather than overlaid series. Overlaying 3 clusters on one chart is visually noisy. Side-by-side lets the eye quickly spot anomalies.

### 7.4 Dashboard: Cross-Cluster Anomaly Detection

| Panel | Type | Query | Purpose |
|-------|------|-------|---------|
| Load Deviation | Time series | `avg(kyb_system_load_1m) - avg(kyb_system_load_1m) over(all clusters)` | Which cluster deviates from the mean |
| Memory Anomaly | Time series | `abs(kyb_system_mem_used_pct - avg(kyb_system_mem_used_pct) over(all clusters)) > 20` | Memory outlier detection |
| Disk Growth Rate | Time series | `rate(kyb_system_disk_used_pct[1h]) by cluster` | Which cluster's disk is filling fastest |

### 7.5 Dashboard Provisioning as Code

All dashboard JSON should be stored in `docs/infra/grafana/dashboards/` and auto-provisioned into Grafana (as per the Grafana provisioning design in `grafana-provisioning.md`):

```
docs/infra/grafana/dashboards/
  ├── cross-cluster-overview.json
  ├── cross-cluster-comparison.json
  ├── cross-cluster-anomaly.json
  └── cross-cluster-events.json
```

---

## 8. Cross-Cluster Query Patterns

### 8.1 CK SQL: Unified Query with Cluster Filter

All cross-cluster queries follow the same pattern:

```sql
-- Template: All clusters, one metric, aggregated view
SELECT
  cluster,
  toStartOfInterval(timestamp, INTERVAL 1 MINUTE) AS interval,
  avg(value) AS avg_val,
  max(value) AS max_val,
  min(value) AS min_val,
  quantile(0.95)(value) AS p95_val
FROM prometheus_samples
WHERE name = 'kyb_system_load_1m'
  AND timestamp > now() - INTERVAL 1 HOUR
  AND cluster IN ('mac-orbstack', 'aliyun', 'office')
GROUP BY cluster, interval
ORDER BY cluster, interval;
```

### 8.2 Handling Asymmetric Service Distribution

Not every cluster runs every service. Queries must handle missing data gracefully:

```sql
-- Correct: LEFT JOIN from cluster registry to metrics
WITH cluster_registry AS (
  SELECT arrayJoin(['mac-orbstack', 'aliyun', 'office']) AS cluster
)
SELECT
  r.cluster,
  avg(m.value) AS avg_disk_used
FROM cluster_registry AS r
LEFT JOIN prometheus_samples AS m
  ON r.cluster = m.cluster
  AND m.name = 'kyb_system_disk_used_pct'
  AND m.timestamp > now() - INTERVAL 5 MINUTE
GROUP BY r.cluster;

-- Result: all 3 clusters appear, even if one has no data (NULL)
-- mac-orbstack | 64.5
-- aliyun       | 22.3
-- office       | NULL   <-- missing data, not silently absent
```

**Grafana handling**: Use `null as zero` or `null as null` depending on the panel. For stat panels, show "N/A" for missing clusters. For time series, show gaps (don't interpolate).

### 8.3 Cross-Cluster Alerting Queries

```sql
-- Cluster down detection: no heartbeat for >5 minutes
SELECT cluster
FROM prometheus_samples
WHERE name = 'kyb_system_cluster_boot_time'
  AND timestamp > now() - INTERVAL 5 MINUTE
GROUP BY cluster
HAVING max(timestamp) < now() - INTERVAL 5 MINUTE;

-- Cross-cluster disk comparison: one cluster significantly worse than others
SELECT cluster, avg(value) AS disk_pct
FROM prometheus_samples
WHERE name = 'kyb_system_disk_used_pct'
  AND timestamp > now() - INTERVAL 5 MINUTE
GROUP BY cluster
HAVING disk_pct > (
  SELECT avg(avg(value)) * 1.5
  FROM prometheus_samples
  WHERE name = 'kyb_system_disk_used_pct'
    AND timestamp > now() - INTERVAL 5 MINUTE
);
```

### 8.4 Grafana Mixed-Datasource Queries

For dashboards that combine CK metrics with other sources (e.g., PostgreSQL query stats, Kafka consumer lag):

```sql
-- CK: cluster health metrics (primary)
SELECT cluster, avg(value) AS load
FROM prometheus_samples
WHERE name = 'kyb_system_load_1m'
  AND timestamp > now() - INTERVAL 5 MINUTE
GROUP BY cluster;

-- PG: database metrics (only on mac-orbstack, handled by Grafana's "no data" state)
SELECT datname, xact_commit, xact_rollback
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1');
```

For this, use Grafana's **mixed datasource** panel or a multi-query panel with per-query datasource override. The CK query always returns data (all clusters). The PG query only returns data for mac-orbstack.

### 8.5 Performance Optimization

| Pattern | Do | Don't |
|---------|----|-------|
| Time filter | Always use `$__timeFilter` or explicit `WHERE timestamp > now() - INTERVAL` | Scan full table with no time filter |
| Aggregation | Downsample in query: `toStartOfInterval(timestamp, INTERVAL $interval)` | Return raw 15s samples to Grafana |
| Cluster filter | Use template variable `$cluster` in WHERE clause | Query all clusters then filter in Grafana |
| Metric filter | Use template variable `$metric_type` to limit name scan | Query all metric names |
| LIMIT | Always add `LIMIT 1000` or `LIMIT 5000` | Return unbounded result sets |
| ORDER BY | Only when needed for specific panels | Default sort on large datasets |

---

## 9. Alert Aggregation & Deduplication

### 9.1 Problem: Per-Cluster Alerts Silo

Without cross-cluster aggregation, each cluster produces its own alerts:

- Aliyun: "disk >85%" (but Aliyun has 40GB disk, 85% = 34GB used)
- Office: "disk >85%" (but Office has 256GB disk, 85% = 217GB used)
- Mac: "disk >85%" (but Mac has 260GB disk, 85% = 221GB used)

The same alert rule fires three times with different context. The operator needs to see them together.

### 9.2 Alert Architecture

```
             ┌─────────────────────────────────────┐
             │        Grafana Alerting              │
             │                                     │
             │  ┌───────────────────────────────┐   │
             │  │  Cross-Cluster Alert Rules     │   │
             │  │  (single rule, all clusters)   │   │
             │  │                                │   │
             │  │  - HighDiskUsage               │   │
             │  │    expr: disk > 85% by cluster │   │
             │  │    for: 5m                     │   │
             │  │                                │   │
             │  │  - ClusterDown                 │   │
             │  │    expr: heartbeat > 5m stale  │   │
             │  │    for: 2m                     │   │
             │  │                                │   │
             │  │  - CrossClusterAnomaly          │   │
             │  │    expr: load > 2x other avg   │   │
             │  │    for: 15m                    │   │
             │  └───────────────────────────────┘   │
             │                  │                    │
             │                  ▼                    │
             │  ┌───────────────────────────────┐   │
             │  │  Single Notification Policy    │   │
             │  │  group_by: [alertname, cluster]│   │
             │  │  receiver: feishu-alerts      │   │
             │  └───────────────────────────────┘   │
             └─────────────────────────────────────┘
```

Key principles:

1. **Single alert rule per condition** -- not "DiskWarning-alyun" and "DiskWarning-office". One rule with `group_by: [cluster]` produces per-cluster alert instances from one definition.
2. **Cluster label in alert** -- every alert instance carries `cluster` label, so the notification says "Disk >85% on **aliyun** (not office)".
3. **Group by alertname + cluster** -- prevents 3 separate Feishu messages for the same condition on different clusters. Grafana groups them into one notification with 3 annotations.
4. **Cross-cluster anomaly rules** -- rules that compare one cluster to others (e.g., "load on aliyun is 3x the average of all other clusters").

### 9.3 Alert Rule Definitions

```yaml
# docs/infra/grafana/provisioning/alerting/resources/cross-cluster-alerts.yaml
apiVersion: 1
groups:
  - name: cross-cluster-health
    folder: kyb-infra-alerts
    interval: 60s
    rules:

      # -- Cluster-level alerts (all clusters evaluated by one rule) --

      - uid: cluster_high_disk
        title: "Cluster Disk > 85%"
        condition: "A"
        data:
          - refId: A
            queryType: sql
            relativeTimeRange: { from: 300, to: 0 }
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT
                  cluster,
                  avg(value) AS disk_pct
                FROM prometheus_samples
                WHERE name = 'kyb_system_disk_used_pct'
                  AND timestamp > now() - INTERVAL 5 MINUTE
                GROUP BY cluster
                HAVING disk_pct > 85
                ORDER BY disk_pct DESC
              format: table
        for: 5m
        annotations:
          summary: "Disk >85% on {{ $labels.cluster }} ({{ $values.disk_pct | humanize }}%)"
          runbook: "dispatch {{ $labels.cluster }} 'docker system prune -af'"
        labels:
          severity: warning

      - uid: cluster_down
        title: "Cluster Down"
        condition: "A"
        data:
          - refId: A
            queryType: sql
            relativeTimeRange: { from: 600, to: 0 }
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT cluster
                FROM prometheus_samples
                WHERE name = 'kyb_system_cluster_boot_time'
                  AND timestamp > now() - INTERVAL 5 MINUTE
                GROUP BY cluster
                HAVING max(timestamp) < now() - INTERVAL 5 MINUTE
              format: table
        for: 2m
        noDataState: Alerting
        annotations:
          summary: "CLUSTER DOWN — {{ $labels.cluster }} no heartbeat for >5 min"
          runbook: "Check Tailscale: tailscale ping {{ $labels.cluster }}. SSH: dispatch {{ $labels.cluster }} 'uptime'"
        labels:
          severity: critical

      # -- Cross-cluster anomaly rules --

      - uid: cross_cluster_load_anomaly
        title: "Load Anomaly (3x other clusters)"
        condition: "A"
        data:
          - refId: A
            queryType: sql
            relativeTimeRange: { from: 900, to: 0 }
            datasourceUid: clickhouse
            model:
              rawSql: |-
                WITH cluster_loads AS (
                  SELECT
                    cluster,
                    avg(value) AS load_avg
                  FROM prometheus_samples
                  WHERE name = 'kyb_system_load_1m'
                    AND timestamp > now() - INTERVAL 15 MINUTE
                  GROUP BY cluster
                ),
                other_avg AS (
                  SELECT avg(load_avg) AS other_mean
                  FROM cluster_loads
                )
                SELECT
                  c.cluster,
                  c.load_avg,
                  o.other_mean,
                  c.load_avg / o.other_mean AS ratio
                FROM cluster_loads AS c
                CROSS JOIN other_avg AS o
                WHERE c.load_avg > o.other_mean * 3
                  AND o.other_mean > 0.5  -- ignore when all clusters are idle
              format: table
        for: 15m
        annotations:
          summary: "Load anomaly on {{ $labels.cluster }} — {{ $values.ratio | humanize }}x other clusters"
          description: "{{ $labels.cluster }} load avg {{ $values.load_avg | humanize }} vs other clusters avg {{ $values.other_mean | humanize }}"
        labels:
          severity: warning

      # -- Missing data alert (a cluster stopped reporting) --

      - uid: cluster_metrics_stale
        title: "Cluster Metrics Stale (>10 min no data)"
        condition: "A"
        data:
          - refId: A
            queryType: sql
            relativeTimeRange: { from: 1200, to: 0 }
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT
                  cluster,
                  max(timestamp) AS last_seen,
                  dateDiff('second', max(timestamp), now()) AS stale_seconds
                FROM prometheus_samples
                WHERE name = 'kyb_system_load_1m'
                  AND timestamp > now() - INTERVAL 1 DAY
                GROUP BY cluster
                HAVING stale_seconds > 600  -- 10 minutes
                ORDER BY stale_seconds DESC
              format: table
        for: 5m
        annotations:
          summary: "Stale metrics from {{ $labels.cluster }} — {{ $values.stale_seconds | humanize }}s since last data"
          runbook: "Check Alloy on cluster: dispatch {{ $labels.cluster }} 'docker ps --filter name=kyb-infra-alloy'"
        labels:
          severity: warning
```

### 9.4 Notification Policy: Grouping by Alert

```yaml
# docs/infra/grafana/provisioning/alerting/policies/cross-cluster-policy.yaml
apiVersion: 1
policies:
  - orgId: 1
    receiver: feishu
    group_by: ["alertname"]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - match:
          severity: critical
        repeat_interval: 30m
        receiver: feishu-critical
```

**Why `group_by: ["alertname"]`**: All instances of "Cluster Disk > 85%" across all clusters are grouped into one Feishu message with multiple annotations. The message says:

```
🔥 Cluster Disk > 85% (3 firing)

  • aliyun: disk 91% — dispatch aliyun 'docker system prune -af'
  • office: disk 87% — dispatch office 'docker system prune -af'
  • mac-orbstack: disk 43% ← resolved
```

Without grouping, you'd get 3 separate Feishu messages for the same disk alert on 3 clusters.

### 9.5 Alert Fatigue Prevention

| Strategy | Implementation | Effect |
|----------|---------------|--------|
| Global group wait | `group_wait: 30s` | Collects all cluster alerts before sending |
| Cooldown per alertname | `repeat_interval: 4h` | Same cluster-disk alert won't re-notify for 4h |
| Critical escalation | `repeat_interval: 30m` | Cluster DOWN repeats every 30 min (more urgent) |
| No per-cluster alert rules | Single rule with `group_by: [cluster]` | One rule to maintain, not N |
| Cross-cluster anomaly hysteresis | `for: 15m` (longer evaluation) | Prevents flapping on transient spikes |

---

## 10. Handling Cluster Asymmetry

### 10.1 Service Distribution Matrix

Not all services run on all clusters. The metric namespace makes this explicit:

```sql
-- Query: "Which services are running on which clusters?"
SELECT
  cluster,
  count(DISTINCT service) AS service_count,
  groupUniqArray(service) AS services
FROM prometheus_samples
WHERE timestamp > now() - INTERVAL 5 MINUTE
GROUP BY cluster
ORDER BY cluster;

-- Result:
-- aliyun       | 4  | ['alloy', 'boss', 'build-runner', 'node-exporter']
-- mac-orbstack | 12 | ['alloy', 'boss', 'clickhouse', 'grafana', 'kafka', 'node-exporter', 'postgresql-14', 'postgresql-15', 'postgresql-16', 'postgresql-17', 'redis', 'sing-box']
-- office       | 5  | ['alloy', 'boss', 'gitlab-mirror', 'nexus-cache', 'node-exporter']
```

### 10.2 Grafana Handling: Missing Services

In Grafana, when a dashboard panel expects a metric from a service that does not exist on a cluster:

1. **Use Grafana's "No data" handling**: Set the panel to "No data = null" (not "No data = 0"). This avoids showing "0 containers" for a service that doesn't run on that cluster.
2. **Template variable filtering**: The `service` template variable should only show services available on the selected cluster(s). Use a filtered query:

```sql
SELECT DISTINCT service FROM prometheus_samples
WHERE cluster IN ($cluster) AND $__timeFilter
```

3. **Repeating panels**: Use Grafana's **repeat panel** feature with `$cluster` variable. Each cluster gets its own row/panel, panels with no data show "N/A" instead of 0.

### 10.3 Composite Health Score

For an at-a-glance cluster health indicator, define a composite score:

```
Score = 1.0 * (heartbeat_ok) +
        0.3 * (1 - disk_used_pct/100) +
        0.2 * (1 - mem_used_pct/100) +
        0.2 * (1 - min(load_1m / cpu_cores, 1))
```

This normalizes across asymmetric clusters:

```sql
SELECT
  cluster,
  -- Composite health score (0.0 = critical, 1.0 = perfect)
  round(
    0.3 * (1 - clamp(disk_pct / 100, 0, 1)) +
    0.3 * (1 - clamp(mem_pct / 100, 0, 1)) +
    0.2 * (1 - clamp(load / cpu_count, 0, 1)) +
    0.2 * (alive ? 1 : 0),
    2
  ) AS health_score
FROM (
  SELECT
    cluster,
    argMax(IF(name = 'kyb_system_disk_used_pct', value, NULL), timestamp) AS disk_pct,
    argMax(IF(name = 'kyb_system_mem_used_pct', value, NULL), timestamp) AS mem_pct,
    argMax(IF(name = 'kyb_system_load_1m', value, NULL), timestamp) AS load,
    argMax(IF(name = 'kyb_system_cpu_count', value, NULL), timestamp) AS cpu_count,
    max(timestamp) > now() - INTERVAL 5 MINUTE AS alive
  FROM prometheus_samples
  WHERE name IN ('kyb_system_disk_used_pct', 'kyb_system_mem_used_pct', 'kyb_system_load_1m', 'kyb_system_cpu_count')
    AND timestamp > now() - INTERVAL 10 MINUTE
  GROUP BY cluster
)
ORDER BY health_score;
```

---

## 11. K8s Cluster Integration (Future)

### 11.1 Architecture for K8s Metrics Aggregation

When a K8s cluster (e.g., Volcano Engine) joins the infrastructure, it introduces:
- **Higher cardinality**: pods, deployments, namespaces
- **Different collection mechanism**: Prometheus Operator, kube-state-metrics
- **Node-level metrics**: via node_exporter DaemonSet
- **Control plane metrics**: API server, scheduler, etcd

```
K8s Cluster (Volcano Engine)
┌────────────────────────────────────────────┐
│  ┌──────────────────────────────────────┐  │
│  │  Prometheus Operator                 │  │
│  │  (scrapes all pods, nodes, services) │  │
│  └───────────┬──────────────────────────┘  │
│              │                              │
│              ▼                              │
│  ┌──────────────────────────────────────┐  │
│  │  Prometheus (per-cluster instance)   │  │
│  │  Retention: 7d local                 │  │
│  └───────────┬──────────────────────────┘  │
│              │                              │
│              ▼                              │
│  ┌──────────────────────────────────────┐  │
│  │  Prometheus Remote Write             │  │
│  │  (downsampled, essential labels)     │  │
│  └───────────┬──────────────────────────┘  │
└──────────────┼─────────────────────────────┘
               │ Tailscale
               ▼
Central CK (Mac/Orbstack)
┌──────────────────────────────────────┐
│  prometheus_samples (unified table)   │
│  Labels: cluster=volcano-k8s          │
│          namespace, pod, container    │
└──────────────────────────────────────┘
```

### 11.2 K8s Label Mapping

K8s metrics carry high-cardinality labels. The remote write must relabel to fit the unified namespace:

```yaml
# Prometheus remote-write relabel config for K8s
remoteWrite:
  - url: "http://100.104.244.99:8123/prometheus/write"
    writeRelabelConfigs:
      # Add cluster label
      - sourceLabels: []
        targetLabel: cluster
        replacement: "volcano-k8s"
      # Add metric_type based on metric name
      - sourceLabels: ["__name__"]
        regex: "(kube_node_status_condition|kube_pod_container_resource_requests|node_.*)"
        targetLabel: metric_type
        replacement: "system"
      - sourceLabels: ["__name__"]
        regex: "(container_cpu|container_memory|container_network).*"
        targetLabel: metric_type
        replacement: "container"
      # Drop high-cardinality pod labels to reduce series count
      - action: labeldrop
        regex: "(pod_template_hash|controller_revision_hash)"
      # Keep only essential K8s labels
      - action: labelkeep
        regex: "(__name__|cluster|metric_type|namespace|pod|container|node|job|instance)"
```

### 11.3 K8s Metric Volume Budget

| Metric Source | Series per Node | Series per Cluster (3 nodes) | Send Interval | Daily Volume |
|---------------|----------------|------------------------------|---------------|-------------|
| kube-state-metrics | -- | ~500 | 60s | ~3.6 MB |
| node_exporter (DaemonSet) | ~200 | ~600 | 60s | ~4.3 MB |
| cAdvisor (kubelet) | ~100/pod | ~3,000 (30 pods) | 60s | ~21.6 MB |
| Control plane | ~100 | ~300 | 60s | ~2.2 MB |
| **Total** | -- | **~4,400** | **60s** | **~31.7 MB/day** |

This is fine for the central CK but requires careful label management to avoid cardinality explosion from pod names.

### 11.4 Unified Alerting with K8s

K8s-specific alert rules follow the same cross-cluster pattern:

```sql
-- Unified: pod crashlooping across all clusters (including K8s)
SELECT
  cluster,
  namespace,
  pod,
  count() AS restart_count
FROM prometheus_samples
WHERE name = 'kube_pod_container_status_restarts_total'
  AND timestamp > now() - INTERVAL 15 MINUTE
GROUP BY cluster, namespace, pod
HAVING restart_count > 5;

-- Unified: node disk pressure (K8s nodes + standalone hosts)
SELECT
  cluster,
  node,
  value AS disk_pct
FROM prometheus_samples
WHERE name = 'node_filesystem_avail_bytes'
  AND timestamp > now() - INTERVAL 5 MINUTE
  AND label('mountpoint') = '/'
GROUP BY cluster, node
HAVING disk_pct / node_filesystem_size_bytes{mountpoint="/"} < 0.15;
```

---

## 12. Failure Modes & Degradation

### 12.1 Failure Scenarios

| Scenario | Impact | Detection | Mitigation |
|----------|--------|-----------|------------|
| Remote cluster offline (node down) | No metrics from Aliyun/Office | `cluster_metrics_stale` alert fires | Dashboards show "stale" badge. CK query returns NULL for missing cluster |
| Tailscale relay degraded | High latency for remote metrics | `kyb_network_tailscale_latency` increases | Remote Alloy WAL buffers up to 3 days. Data catches up when latency normalizes |
| CK itself down | No metrics written at all | Alloy reports remote write errors | Alloy WAL buffers on all clusters. CK restart = catch-up replay |
| Alloy on remote cluster crashes | No local collection, no remote write | Boss heartbeat shows Alloy container missing | Boss auto-restarts Alloy (docker restart policy: unless-stopped) |
| Network partition (split brain) | Some clusters can reach CK, some cannot | Partial metrics in CK | Dashboard shows partial data with "degraded" indicator |
| Aliyun outbound bandwidth saturated | Remote write delayed or dropped | Prometheus remote-write retries | Alloy rate-limits itself. WAL grows but drops oldest samples after 5000 capacity |

### 12.2 Dashboard Degradation Indicators

Every cross-cluster dashboard should show:

1. **Data freshness** per cluster: a table with `cluster` and `last_data_seconds_ago`
2. **Staleness threshold**: color code: green (<60s), yellow (60-300s), red (>300s)
3. **Composite health**: total clusters / reporting clusters

```sql
-- Data freshness panel (top of every dashboard)
SELECT
  cluster,
  max(timestamp) AS last_data,
  dateDiff('second', max(timestamp), now()) AS stale_seconds,
  multiIf(
    stale_seconds < 60, 'OK',
    stale_seconds < 300, 'STALE',
    'DOWN'
  ) AS status
FROM prometheus_samples
WHERE name = 'kyb_system_load_1m'
  AND timestamp > now() - INTERVAL 1 DAY
GROUP BY cluster
ORDER BY status, stale_seconds DESC;
```

### 12.3 Recovery Procedures

```bash
# 1. Alloy down on remote cluster
dispatch aliyun "docker ps --filter name=kyb-infra-alloy"
dispatch aliyun "docker restart kyb-infra-alloy"
# Or recreate:
dispatch aliyun "docker rm -f kyb-infra-alloy && <deploy command>"

# 2. WAL overflow (if CK was down for extended period)
dispatch aliyun "docker exec kyb-infra-alloy du -sh /tmp/alloy-wal"
dispatch aliyun "docker exec kyb-infra-alloy rm -rf /tmp/alloy-wal/*"
dispatch aliyun "docker restart kyb-infra-alloy"
# Note: clears backlog, newer data will be collected fresh

# 3. Tailscale connectivity issue
dispatch aliyun "docker exec kyb-infra-boss tailscale ping 100.104.244.99"
dispatch aliyun "docker exec kyb-infra-boss curl -sI http://100.104.244.99:8123"

# 4. CK full disk (can't accept writes)
# - Free disk on Mac
# - Or drop old Prometheus partitions:
ssh dongqs-mac 'docker exec kyb-infra-clickhouse bash -c "
  ALTER TABLE prometheus_samples DROP PARTITION WHERE date < now() - 30;
"'
```

---

## 13. Operational Runbook

### 13.1 Deploy Alloy on a Remote Cluster (First Time)

```bash
# Set variables
CLUSTER_NAME="aliyun"
CK_ENDPOINT="http://100.104.244.99:8123"

# Copy config to remote host
ssh sim "mkdir -p /home/dongqs/alloy-config"
scp config.alloy dongqs@47.100.71.220:/home/dongqs/alloy-config/

# Create and start Alloy container
ssh sim "docker run -d \
  --name kyb-infra-alloy \
  --restart unless-stopped \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /home/dongqs/alloy-config:/etc/alloy:ro \
  -e CLUSTER_NAME=${CLUSTER_NAME} \
  -e CK_ENDPOINT=${CK_ENDPOINT} \
  grafana/alloy:latest \
  run --server.http.listen-addr=0.0.0.0:12345 /etc/alloy/config.alloy"

# Verify
ssh sim "docker logs kyb-infra-alloy --tail 10"
ssh sim "curl -s http://localhost:12345/-/healthy"

# Check CK for incoming data
curl -s "http://localhost:8123?query=SELECT%20count()%20FROM%20prometheus_samples%20WHERE%20cluster%3D'aliyun'"
```

### 13.2 Verify Cross-Cluster Data Flow

```bash
# 1. Check that all clusters are reporting
curl -s "http://localhost:8123" -d "
SELECT cluster, count(), max(timestamp)
FROM prometheus_samples
WHERE name = 'kyb_system_load_1m'
  AND timestamp > now() - INTERVAL 5 MINUTE
GROUP BY cluster"

# Expected: 3 rows (mac-orbstack, aliyun, office) with timestamps within 60s

# 2. Check label consistency (all metrics have required labels)
curl -s "http://localhost:8123" -d "
SELECT
  cluster,
  countIf(service = '') AS missing_service,
  countIf(metric_type = '') AS missing_metric_type
FROM prometheus_samples
WHERE timestamp > now() - INTERVAL 5 MINUTE
GROUP BY cluster
HAVING missing_service > 0 OR missing_metric_type > 0"

# Expected: empty result (no missing labels)

# 3. Check remote write latency
curl -s "http://localhost:8123" -d "
SELECT
  cluster,
  dateDiff('second', max(timestamp), now()) AS send_lag_seconds
FROM prometheus_samples
WHERE name = 'kyb_system_load_1m'
  AND timestamp > now() - INTERVAL 5 MINUTE
GROUP BY cluster"

# Expected: all clusters <120s (with 60s send interval + 60s grace)
```

### 13.3 Grafana Datasource Setup

```bash
# Add ClickHouse datasource with macro support
curl -X POST http://admin:admin@localhost:3000/api/datasources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ClickHouse (Metrics)",
    "type": "grafana-clickhouse-datasource",
    "url": "http://host.orb.internal:8123",
    "access": "proxy",
    "isDefault": true,
    "jsonData": {
      "defaultDatabase": "default",
      "dialect": "clickhouse",
      "useSchema": false
    }
  }'
```

### 13.4 Adding a New Cluster (Checklist)

```
[ ] Cluster has Grafana Alloy installed and running
[ ] Alloy config has correct CLUSTER_NAME env var
[ ] Alloy config has correct CK_ENDPOINT pointing to central CK
[ ] Alloy is reachable from central Grafana (debug endpoint)
[ ] Metrics appear in prometheus_samples with cluster label
[ ] Cluster appears in the $cluster template variable dropdown
[ ] Cluster appears in the "Cluster Health Matrix" dashboard
[ ] Cross-cluster alerts evaluate for the new cluster
[ ] Feishu notification includes the new cluster label
[ ] Disk/retention budget updated for additional ~200-500 series
```

---

## 14. Implementation Plan

### Phase 1: Label Standardization (Day 1)

**Goal**: All existing metrics carry the standard label taxonomy.

- [ ] Update heartbeat curl loops to include `cluster` label
- [ ] Create `boss_heartbeats_v2` MV in CK for label migration
- [ ] Validate all existing Grafana queries still work after MV creation
- [ ] Write label taxonomy documentation (this document, Section 4)

### Phase 2: Mac/Orbstack Alloy Deployment (Day 1-2)

**Goal**: Full-resolution metrics pipeline on the central cluster.

- [ ] Deploy Grafana Alloy on Mac/Orbstack with `CLUSTER_NAME=mac-orbstack`
- [ ] Configure Docker service discovery with label filtering
- [ ] Apply `telemetry=enabled` labels to existing infra containers
- [ ] Verify metrics land in `prometheus_samples`
- [ ] Build "Global Cluster Overview" dashboard (Section 7.2)
- [ ] Build "Cluster Comparison" dashboard (Section 7.3)

### Phase 3: Remote Cluster Alloy Deployment (Day 2-3)

**Goal**: Downsampled metrics from Aliyun and Office.

- [ ] Write remote cluster Alloy config (downsampled, 60s batch)
- [ ] Deploy Alloy on Aliyun (sim) via SSH
- [ ] Deploy Alloy on Office (nuc8) via SSH
- [ ] Verify metrics appear in CK with `cluster=aliyun` and `cluster=office`
- [ ] Validate bandwidth consumption on Aliyun (should be <1 MB/day)
- [ ] Test WAL behavior: stop Alloy, restart, verify catch-up

### Phase 4: Heartbeat Migration (Day 3)

**Goal**: Replace curl-based heartbeats with Alloy metrics.

- [ ] Add boss-specific scrape target (port 9101) to Alloy config
- [ ] Create MV in CK: `prometheus_samples` -> `boss_heartbeats` format
- [ ] Validate MV produces identical values to curl loops
- [ ] Stop curl heartbeat loops on all cluster bosses
- [ ] Update Grafana heartbeat dashboards to query MV or direct Prometheus samples

### Phase 5: Cross-Cluster Alerting (Day 3-4)

**Goal**: Unified alerts with cross-cluster deduplication.

- [ ] Write cross-cluster alert rules (Section 9.3)
- [ ] Configure Grafana notification policy with grouping
- [ ] Test: simulate Aliyun going offline, verify Feishu notification shows "Cluster DOWN: aliyun"
- [ ] Test: simulate high disk on two clusters, verify one grouped notification
- [ ] Configure `repeat_interval` to prevent alert fatigue

### Phase 6: Dashboards & Refinement (Day 4-5)

**Goal**: Polished cross-cluster dashboards with anomaly detection.

- [ ] Build "Cross-Cluster Anomaly Detection" dashboard (Section 7.4)
- [ ] Add composite health score panel
- [ ] Add stale data indicators to all dashboards
- [ ] Export all dashboard JSON to `docs/infra/grafana/dashboards/`
- [ ] Auto-provision via Grafana provisioning (as per `grafana-provisioning.md`)

### Phase 7: K8s Integration (Future, TBD)

- [ ] Deploy Prometheus Operator on K8s cluster
- [ ] Configure remote write with label mapping (Section 11.2)
- [ ] K8s metrics appear in same `prometheus_samples` table
- [ ] K8s cluster selectable in all cross-cluster dashboards

---

## Appendix A: CK Schema for Cross-Cluster Metrics

```sql
-- Core metrics table (Prometheus remote-write format)
CREATE TABLE prometheus_samples (
  date Date DEFAULT toDate(timestamp),
  timestamp DateTime64(9),
  name String,
  value Float64,
  labels Map(String, String),
  cluster String DEFAULT '',
  service String DEFAULT '',
  metric_type String DEFAULT '',
  host String DEFAULT ''
) ENGINE = MergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (name, timestamp)
TTL date + INTERVAL 90 DAY;

-- Downsampled aggregations (1-minute)
CREATE MATERIALIZED VIEW prometheus_metrics_1m
TO prometheus_metrics_1m AS
SELECT
  name,
  cluster,
  service,
  metric_type,
  toStartOfMinute(timestamp) AS minute,
  avg(value) AS avg_val,
  max(value) AS max_val,
  min(value) AS min_val,
  quantile(0.5)(value) AS p50,
  quantile(0.9)(value) AS p90,
  quantile(0.99)(value) AS p99,
  count() AS sample_count
FROM prometheus_samples
GROUP BY name, cluster, service, metric_type, minute;

-- Downsampled aggregations (1-hour, for long-term retention)
CREATE MATERIALIZED VIEW prometheus_metrics_1h
TO prometheus_metrics_1h AS
SELECT
  name,
  cluster,
  service,
  metric_type,
  toStartOfHour(timestamp) AS hour,
  avg(value) AS avg_val,
  max(value) AS max_val,
  min(value) AS min_val,
  quantile(0.5)(value) AS p50,
  quantile(0.9)(value) AS p90,
  quantile(0.99)(value) AS p99,
  count() AS sample_count
FROM prometheus_samples
GROUP BY name, cluster, service, metric_type, hour;

-- Cluster events table (for boss online/offline, deploy events)
CREATE TABLE cluster_events (
  timestamp DateTime64(3) DEFAULT now64(),
  cluster String,
  event_type String,
  severity String DEFAULT 'info',
  message String,
  payload String DEFAULT ''  -- JSON
) ENGINE = MergeTree
ORDER BY (cluster, timestamp)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

## Appendix B: Metric Name Registry

All cross-cluster metric names must be registered here. Any addition or deprecation requires updating this registry.

| Metric Name | Type | Labels | Description | Deprecation |
|-------------|------|--------|-------------|-------------|
| `kyb_system_cluster_boot_time` | Gauge | cluster, host | Unix timestamp of Alloy/kernel boot | - |
| `kyb_system_container_running` | Gauge | cluster, service | Running container count | - |
| `kyb_system_container_total` | Gauge | cluster, service | Total container count (including stopped) | - |
| `kyb_system_disk_used_pct` | Gauge | cluster, mountpoint | Disk usage percentage | - |
| `kyb_system_mem_used_pct` | Gauge | cluster | Memory usage percentage | - |
| `kyb_system_load_1m` | Gauge | cluster | 1-minute load average | - |
| `kyb_system_load_5m` | Gauge | cluster | 5-minute load average | - |
| `kyb_system_load_15m` | Gauge | cluster | 15-minute load average | - |
| `kyb_system_cpu_count` | Gauge | cluster | Number of CPU cores | - |
| `kyb_system_uptime_seconds` | Counter | cluster, host | System uptime | - |
| `kyb_network_proxy_traffic_bytes` | Counter | cluster, direction | sing-box proxy traffic | - |
| `kyb_network_tailscale_latency` | Gauge | cluster, peer | Tailscale ping latency to peer | - |
| `kyb_application_messages_total` | Counter | cluster, status | cc-connect messages processed | - |
| `kyb_application_turn_duration` | Histogram | cluster | cc-connect turn latency | - |
| `kyb_storage_pg_commit_latency` | Histogram | cluster, pg_version | PG commit latency | - |
| `kyb_storage_redis_hit_rate` | Gauge | cluster | Redis cache hit rate | - |
| `kyb_storage_kafka_consumer_lag` | Gauge | cluster, consumer_group | Kafka consumer lag | - |
| `kyb_storage_ck_query_rate` | Gauge | cluster | ClickHouse query rate | - |
| `kyb_container_cpu_usage` | Gauge | cluster, container_name | CPU usage per container | Replaces `container_cpu_*` |
| `kyb_container_memory_usage` | Gauge | cluster, container_name | Memory usage per container | Replaces `container_memory_*` |
| `kyb_container_network_rx_bytes` | Counter | cluster, container_name | Network received bytes | Replaces `container_network_*` |
| `kyb_container_network_tx_bytes` | Counter | cluster, container_name | Network transmitted bytes | Replaces `container_network_*` |
| `kyb_container_restart_count` | Counter | cluster, container_name | Container restart count | - |
| `kyb_event_boss_online` | Event | cluster | Boss container started | - |
| `kyb_event_boss_offline` | Event | cluster | Boss container stopped | - |
| `kyb_event_cluster_deploy` | Event | cluster, service | Service deployed/updated | - |

## Appendix C: Estimated Storage Requirements

| Data | Daily Ingestion | 30-Day Retention | 90-Day Retention | 1-Year (downsampled) |
|------|----------------|------------------|------------------|---------------------|
| Raw samples (Mac, 15s) | ~307 MB | ~9.2 GB | ~27.6 GB | -- |
| Raw samples (Remote, 60s) | ~3 MB | ~90 MB | ~270 MB | -- |
| 1m downsampled | ~20 MB | ~600 MB | ~1.8 GB | -- |
| 1h downsampled | ~0.5 MB | ~15 MB | ~45 MB | ~180 MB |
| Cluster events | ~1 MB | ~30 MB | ~90 MB | ~365 MB |
| **Total** | **~331 MB** | **~9.9 GB** | **~29.8 GB** | **~545 MB (1h)** |

**Recommendation**: 90-day retention for raw samples, 1-year for 1h downsampled. Total storage: ~30 GB for 90 days + ~0.5 GB for annual 1h data = **~31 GB**. This is well within Mac's 260 GB SSD.

---

## Appendix D: Related Documents

| Document | Relation |
|----------|----------|
| `multi-cluster-boss-architecture.md` | Cross-cluster boss hierarchy and heartbeat protocol |
| `prometheus-scrape.md` | Prometheus scrape config design (replaced by Alloy for remote clusters) |
| `grafana-alloy.md` | Grafana Alloy as unified telemetry collector (Alloy implementation details) |
| `grafana-provisioning.md` | Grafana provisioning as code (dashboard JSON management) |
| `heartbeat-reliability.md` | Heartbeat reliability improvements (replaced by Alloy) |
| `node-exporter.md` | node_exporter host metrics (per-cluster deployment) |
| `disk-growth.md` | Disk growth monitoring (cross-cluster disk trend queries) |

> **Summary**: Cross-cluster metrics aggregation uses a tiered model: Grafana Alloy per cluster collects metrics locally, downsamples for remote clusters, and ships via Prometheus remote-write to central ClickHouse on Mac/Orbstack. Standard labels (cluster, service, metric_type) enable unified queries. Grafana dashboards use template variables for multi-cluster views and comparison. Alerts are defined once per condition and deduplicated across clusters via Grafana grouping. Bandwidth for remote clusters is negligible (<1 MB/day per cluster), and the WAL provides resilience during network or CK outages. The design extends to K8s clusters through Prometheus Operator remote-write with label mapping.

> ／人◕ ‿‿ ◕人＼
