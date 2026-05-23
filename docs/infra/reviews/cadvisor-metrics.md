---
decision: 稍后做
---

# cAdvisor Metrics: Container Resource Monitoring

**Status:** Draft design
**Date:** 2026-05-23
**Author:** Boss
**File:** `docs/infra/reviews/cadvisor-metrics.md`

---

## 1. Background

We have 18+ containers running across the kyb-infra stack (ClickHouse, Grafana, Kafka, PostgreSQL x4, Redis, sing-box, cc-connect, boss agents, registry cache, etc.). Currently there is **no container-level resource monitoring**:

| Gap | Impact |
|-----|--------|
| No per-container CPU/memory visibility | Can't detect OOM, CPU steal, or resource leaks |
| No network traffic per container | Can't identify bandwidth hogs or network anomalies |
| No disk usage per container overlay | Can't tell which container is filling the disk |
| No historical container metrics | Can't do capacity planning or trend analysis |

cAdvisor (container Advisor) solves this: it reads cgroup stats from the Docker daemon and exposes per-container CPU, memory, network, disk, and filesystem metrics in Prometheus format -- zero instrumentation, no application changes.

### Existing Observability Stack

| Component | Status | Notes |
|-----------|--------|-------|
| **ClickHouse** 24.2-alpine | Running (`kyb-infra-clickhouse`) | Primary long-term storage |
| **Grafana** 11.x | Running (`kyb-infra-grafana`) | ClickHouse datasource configured |
| **Vector** | Not deployed | Referenced in designs but not running |
| **Prometheus** | Not deployed | New component needed |
| **cAdvisor** | Not deployed | New component needed |
| **AlertManager** | Not deployed | Future phase |

## 2. Architecture

### Recommended: Hybrid Prometheus + ClickHouse

```
                                      ┌──────────────────┐
                                      │   Grafana 11.x    │
                                      │  (kyb-infra-      │
                                      │   grafana)        │
                                      └──┬─────────────┬──┘
                                         │             │
                                    PromQL        SQL (CK
                                    (real-time)    datasource)
                                         │             │
                                         ▼             ▼
                                 ┌──────────┐  ┌──────────────┐
                                 │Prometheus │  │  ClickHouse  │
                                 │(15d ret.) │  │(indefinite)  │
                                 └─────┬─────┘  └──────┬───────┘
                                       │ scrape         │
                                       ▼                ▲
                                 ┌──────────┐           │
                                 │ cAdvisor  │───────────┘
                                 │(:8080     │  (Vector scrape
                                 │ /metrics) │   → CK sink)
                                 └────┬─────┘
                                      │
                                      ▼
                              ┌─────────────────┐
                              │  Docker Daemon   │
                              │ (cgroups, stats, │
                              │  /sys/fs/cgroup) │
                              └─────────────────┘
```

**Two tiers:**

| Tier | Path | Latency | Retention | Purpose |
|------|------|---------|-----------|---------|
| **T1: Real-time** | cAdvisor → Prometheus → Grafana | ~15s | 15 days | Dashboards, alerting, live debugging |
| **T2: Historical** | cAdvisor → Prometheus → Vector → ClickHouse → Grafana | ~60s | Indefinite | Trend analysis, capacity planning, audits |

**Why hybrid:**
- Prometheus gives us PromQL, alerting (`rate()`, `histogram_quantile()`), and Grafana's native Prometheus datasource
- ClickHouse gives us cost-effective long-term storage (Prometheus's local TSDB is limited by disk)
- Vector can scrape Prometheus's `/api/v1/query` for rollups, or we use Prometheus remote write to a ClickHouse-compatible receiver

### Alternative: ClickHouse-only

```
cAdvisor → Vector (prometheus_scrape) → ClickHouse → Grafana
```

Simpler (no Prometheus), but loses PromQL for alerting and real-time dashboards. Viable if we deploy a separate Prometheus later for alerting only.

### Chosen: Hybrid until infra scales past 50 containers; then re-evaluate.

## 3. cAdvisor Deployment

### Docker Run

```bash
docker run -d \
  --name kyb-infra-cadvisor \
  --network kyb-net \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /sys:/sys:ro \
  -v /var/lib/docker/:/var/lib/docker:ro \
  -v /dev/disk/:/dev/disk:ro \
  -v /etc/machine-id:/etc/machine-id:ro \
  --privileged \
  gcr.io/cadvisor/cadvisor:v0.49.1 \
  -docker_only=true \
  -housekeeping_interval=10s \
  -max_housekeeping_interval=30s \
  -global_housekeeping_interval=60s
```

### Flag Explanation

| Flag / Mount | Purpose |
|-------------|---------|
| `--network kyb-net` | Reachable by Prometheus and other infra containers |
| `-v /var/run/docker.sock:ro` | Docker API access to list containers and fetch stats |
| `-v /sys:/sys:ro` | cgroup filesystem access for CPU/memory stats |
| `-v /var/lib/docker:ro` | Docker overlay2 storage for image/filesystem metrics |
| `-v /dev/disk:ro` | Block device stats for disk I/O |
| `--privileged` | Required for cgroup read access on some kernels |
| `-docker_only=true` | Only monitor Docker containers (skip raw cgroups) |
| `-housekeeping_keeping_interval=10s` | Per-container stat refresh interval |
| `-global_housekeeping_interval=60s` | Rescan container list interval |

### cAdvisor Exposed Metrics (Key Subset)

cAdvisor exposes ~300+ metrics. The ones we care about:

| Category | Metric | Type | Unit |
|----------|--------|------|------|
| **CPU** | `container_cpu_usage_seconds_total` | counter | seconds |
| | `container_cpu_cfs_periods_total` | counter | count |
| | `container_cpu_cfs_throttled_periods_total` | counter | count |
| | `container_cpu_load_average_10s` | gauge | fraction |
| | `container_cpu_system_seconds_total` | counter | seconds |
| | `container_cpu_user_seconds_total` | counter | seconds |
| **Memory** | `container_memory_usage_bytes` | gauge | bytes |
| | `container_memory_working_set_bytes` | gauge | bytes |
| | `container_memory_rss` | gauge | bytes |
| | `container_memory_cache` | gauge | bytes |
| | `container_memory_swap` | gauge | bytes |
| | `container_memory_failures_total` | counter | count |
| | `container_memory_max_usage_bytes` | gauge | bytes |
| | `container_oom_events_total` | counter | count |
| **Network** | `container_network_receive_bytes_total` | counter | bytes |
| | `container_network_transmit_bytes_total` | counter | bytes |
| | `container_network_receive_packets_total` | counter | count |
| | `container_network_transmit_packets_total` | counter | count |
| | `container_network_receive_errors_total` | counter | count |
| | `container_network_transmit_errors_total` | counter | count |
| | `container_network_receive_dropped_total` | counter | count |
| | `container_network_transmit_dropped_total` | counter | count |
| **Disk** | `container_fs_usage_bytes` | gauge | bytes |
| | `container_fs_limit_bytes` | gauge | bytes |
| | `container_fs_reads_bytes_total` | counter | bytes |
| | `container_fs_writes_bytes_total` | counter | bytes |
| | `container_fs_reads_total` | counter | count |
| | `container_fs_writes_total` | counter | count |
| | `container_fs_io_current` | gauge | count |

### Key Labels

Every cAdvisor metric carries these labels:

| Label | Source | Example |
|-------|--------|---------|
| `id` | Container ID (full SHA256) | `a1b2c3d4...` |
| `name` | Container name | `kyb-infra-clickhouse` |
| `image` | Container image | `clickhouse/clickhouse-server:24.2-alpine` |
| `container_label_*` | Docker labels on container | `container_label_com_docker_compose_service=clickhouse` |

All Grafana panels and CK queries should filter/group by `name` (container name). Images change frequently; names are stable.

## 4. Prometheus Deployment

### Docker Run

```bash
docker run -d \
  --name kyb-infra-prometheus \
  --network kyb-net \
  --restart unless-stopped \
  -p 9090:9090 \
  -v prometheus-data:/prometheus \
  -v /home/dev/projects/kyb/infra/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
  prom/prometheus:v2.53.0 \
  --storage.tsdb.retention.time=15d \
  --storage.tsdb.retention.size=10GB \
  --web.enable-admin-api
```

### Prometheus Config (`infra/prometheus/prometheus.yml`)

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: kyb-infra

scrape_configs:
  - job_name: 'cadvisor'
    scrape_interval: 15s
    scrape_timeout: 10s
    metrics_path: /metrics
    scheme: http
    static_configs:
      - targets:
        - 'kyb-infra-cadvisor:8080'
    relabel_configs:
      # Strip container_label_ prefix for cleaner label names
      - source_labels: [__meta_kubernetes_*]
        action: drop
      # Keep only running containers (cAdvisor may show exited ones briefly)
      - source_labels: [__name__]
        regex: 'container_.*'
        action: keep

  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

### Why 15s Scrape

- 17 containers × ~300 time series = ~5100 series per scrape
- At 15s interval: ~29K scrapes/day, ~60MB/day uncompressed
- Prometheus compresses to ~15MB/day on disk
- 15d retention at 10GB cap = well within budget

## 5. ClickHouse Integration (Long-Term Storage)

### 5.1 Raw Metrics Table

Store every cAdvisor scrape sample as a row. This enables arbitrary PromQL-like queries via SQL.

```sql
CREATE DATABASE IF NOT EXISTS monitor;

CREATE TABLE monitor.container_metrics
(
    event_time      DateTime64(3),
    container_name  LowCardinality(String),
    container_image LowCardinality(String),
    metric_name     LowCardinality(String),
    labels          Map(LowCardinality(String), String),
    value           Float64,
    scrape_interval UInt32 COMMENT 'Expected scrape interval in seconds, for rate() calculations'
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, container_name, metric_name)
TTL event_time + INTERVAL 90 DAY DELETE
SETTINGS index_granularity = 8192;
```

**Why this schema:**
- `metric_name` as LowCardinality for filter efficiency (~300 distinct metric names)
- `container_name` as LowCardinality (~20 distinct names)
- `labels` as Map for flexible label handling (device, interface, etc.)
- TTL 90 days on raw data; keep aggregates indefinitely (see below)
- Partition by month for efficient time-range pruning

### 5.2 Aggregated Rollups

Raw metrics at 15s granularity produce ~17K rows/hour. For long-term trends (>90 days), create hourly/daily rollups.

```sql
-- Hourly rollup (retain 1 year)
CREATE TABLE monitor.container_metrics_hourly
(
    event_hour      DateTime,
    container_name  LowCardinality(String),
    metric_name     LowCardinality(String),
    metric_type     LowCardinality(String),  -- 'counter', 'gauge'
    labels          Map(LowCardinality(String), String),
    avg_val         Float64,
    min_val         Float64,
    max_val         Float64,
    p50_val         Float64,
    p95_val         Float64,
    p99_val         Float64,
    sample_count    UInt32
)
ENGINE = SummingMergeTree
PARTITION BY toYYYYMM(event_hour)
ORDER BY (event_hour, container_name, metric_name, labels)
TTL event_hour + INTERVAL 365 DAY DELETE;

-- Daily rollup (retain 3 years)
CREATE TABLE monitor.container_metrics_daily
(
    event_date      Date,
    container_name  LowCardinality(String),
    metric_name     LowCardinality(String),
    metric_type     LowCardinality(String),
    labels          Map(LowCardinality(String), String),
    avg_val         Float64,
    min_val         Float64,
    max_val         Float64,
    p50_val         Float64,
    p95_val         Float64,
    p99_val         Float64,
    sample_count    UInt32
)
ENGINE = SummingMergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, container_name, metric_name, labels)
TTL event_date + INTERVAL 3 YEAR DELETE;
```

### 5.3 Rollup Materialized View

Use a ClickHouse materialized view to populate hourly aggregates as data arrives.

```sql
CREATE MATERIALIZED VIEW monitor.container_metrics_hourly_mv
TO monitor.container_metrics_hourly
AS
SELECT
    toStartOfHour(event_time)   AS event_hour,
    container_name,
    metric_name,
    multiIf(
        metric_name LIKE '%_total' OR metric_name LIKE '%_seconds_total',
        'counter',
        'gauge'
    )                           AS metric_type,
    labels,
    avg(value)                  AS avg_val,
    min(value)                  AS min_val,
    max(value)                  AS max_val,
    quantile(0.50)(value)       AS p50_val,
    quantile(0.95)(value)       AS p95_val,
    quantile(0.99)(value)       AS p99_val,
    count()                     AS sample_count
FROM monitor.container_metrics
GROUP BY
    toStartOfHour(event_time),
    container_name,
    metric_name,
    metric_type,
    labels;
```

### 5.4 Ingestion Pipeline

#### Option A: Vector (recommended)

Install a Vector container that scrapes cAdvisor's `/metrics` endpoint and writes to ClickHouse.

```bash
docker run -d \
  --name kyb-infra-vector \
  --network kyb-net \
  --restart unless-stopped \
  -v vector-data:/var/lib/vector \
  timberio/vector:0.38.0-alpine
```

Vector config (`/etc/vector/vector.toml`):

```toml
[sources.cadvisor_scrape]
type = "prometheus_scrape"
endpoints = ["http://kyb-infra-cadvisor:8080/metrics"]
scrape_interval_secs = 60
instance_tag = "container"

[transforms.cadvisor_filter]
type = "remap"
inputs = ["cadvisor_scrape"]
source = '''
  # Keep only container_* metrics
  if !includes(["container_cpu_", "container_memory_", "container_network_", "container_fs_", "container_oom_"], .name) {
    abort
  }
'''

[transforms.cadvisor_reshape]
type = "remap"
inputs = ["cadvisor_filter"]
source = '''
  # Extract container name from labels
  .container_name = del(.tags.name) ?? "unknown"
  .container_image = del(.tags.image) ?? "unknown"
  .metric_name = del(.name)
  .value = del(.value)
  .labels = {}
  .labels.device = del(.tags.device) ?? ""
  .labels.interface = del(.tags.interface) ?? ""
  # Drop remaining tags
  del(.tags)
'''

[sinks.cadvisor_clickhouse]
type = "clickhouse"
inputs = ["cadvisor_reshape"]
endpoint = "http://kyb-infra-clickhouse:8123"
database = "monitor"
table = "container_metrics"
healthcheck = true
encoding.codec = "json"

# Batch for efficiency
batch.max_events = 1000
batch.timeout_secs = 10
request.retry_attempts = 3
```

**Important:** Vector must be on the same `kyb-net` network and the container must have access to the host's cgroup filesystem (currently not needed for scraping, but Vector itself reads `/sys/fs/cgroup` if `source.type = "docker"` is used).

#### Option B: prom2click (lightweight alternative)

[prom2click](https://github.com/cyriltovena/prom2click) is a ~5MB Go binary that scrapes Prometheus endpoints and writes to ClickHouse. No Vector dependency.

```bash
docker run -d \
  --name kyb-infra-prom2click \
  --network kyb-net \
  prom2click/prom2click:latest \
  -scrape.url=http://kyb-infra-cadvisor:8080/metrics \
  -clickhouse.dsn=http://kyb-infra-clickhouse:8123/monitor \
  -scrape.interval=60s
```

#### Chosen: Option A (Vector). We already have Vector in the design stack (bridge-ck-ingestion.md references it). One Vector instance can scrape multiple sources (cAdvisor, cc-connect logs, patrol traces) and write to multiple CK tables.

### 5.5 Storage Estimation

| Granularity | Rows/day | Size/day | Retention | Total |
|-------------|----------|----------|-----------|-------|
| Raw (15s) | ~410K | ~40MB | 90 days | ~3.6 GB |
| Hourly rollup | ~7K | ~700KB | 365 days | ~255 MB |
| Daily rollup | ~300 | ~30KB | 3 years | ~33 MB |

**Total ClickHouse storage for container metrics: ~3.9 GB (first 90 days), growing ~120MB/month after rollup.**

Prometheus TSDB: ~15MB/day × 15 days = ~225MB.

## 6. Grafana Datasource Configuration

### Prometheus Datasource

Provision via `/etc/grafana/provisioning/datasources/prometheus.yaml`:

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://kyb-infra-prometheus:9090
    isDefault: false
    jsonData:
      timeInterval: 15s
      queryTimeout: 30s
```

### Grafana Restart

```bash
docker restart kyb-infra-grafana  # or, if provisioned at startup:
docker exec kyb-infra-grafana ls /etc/grafana/provisioning/datasources/
```

## 7. Grafana Dashboards

### Dashboard: Container Resource Overview

**Name:** `Infra / Containers / Resource Overview`
**Refresh:** 30s
**Time range default:** Last 6h

#### Row 1: Fleet Overview (Stat Panels)

| Panel | Type | Source | Query |
|-------|------|--------|-------|
| Containers | Stat | Prometheus | `count(count by(name) (container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}))` |
| Total CPU Cores | Stat | Prometheus | `sum(rate(container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}[1m]))` |
| Total Memory | Stat (gauge) | Prometheus | `sum(container_memory_working_set_bytes{name=~"kyb-infra-.*"})` |
| Total Disk | Stat | Prometheus | `sum(container_fs_usage_bytes{name=~"kyb-infra-.*"})` |
| OOM Events (24h) | Stat | Prometheus | `sum(increase(container_oom_events_total{name=~"kyb-infra-.*"}[24h]))` |

#### Row 2: CPU Usage (per container)

| Panel | Type | Query |
|-------|------|-------|
| CPU Usage (cores) | Time series (stacked) | `sum by(name) (rate(container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}[1m]))` |
| CPU Throttle Ratio | Time series | `sum by(name) (rate(container_cpu_cfs_throttled_periods_total{name=~"kyb-infra-.*"}[1m])) / sum by(name) (rate(container_cpu_cfs_periods_total{name=~"kyb-infra-.*"}[1m]))` |
| Top CPU Consumers | Bar gauge | `topk(10, sum by(name) (rate(container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}[5m])))` |

#### Row 3: Memory Usage (per container)

| Panel | Type | Query |
|-------|------|-------|
| Memory Working Set | Time series (stacked) | `sum by(name) (container_memory_working_set_bytes{name=~"kyb-infra-.*"})` |
| Memory Usage (%) | Time series | `container_memory_working_set_bytes{name=~"kyb-infra-.*"} / on(name) container_spec_memory_limit_bytes{name=~"kyb-infra-.*"} * 100` |
| Top Memory Consumers | Bar gauge | `topk(10, container_memory_working_set_bytes{name=~"kyb-infra-.*"})` |

#### Row 4: Network Throughput

| Panel | Type | Query |
|-------|------|-------|
| Network RX | Time series (stacked) | `sum by(name) (rate(container_network_receive_bytes_total{name=~"kyb-infra-.*"}[1m]))` |
| Network TX | Time series (stacked) | `sum by(name) (rate(container_network_transmit_bytes_total{name=~"kyb-infra-.*"}[1m]))` |
| Network Errors | Time series | `sum by(name) (rate(container_network_receive_errors_total{name=~"kyb-infra-.*"}[1m]) + rate(container_network_transmit_errors_total{name=~"kyb-infra-.*"}[1m]))` |
| Top RX Consumers | Bar gauge | `topk(10, sum by(name) (rate(container_network_receive_bytes_total{name=~"kyb-infra-.*"}[5m])))` |

#### Row 5: Disk I/O

| Panel | Type | Query |
|-------|------|-------|
| Disk Read | Time series (stacked) | `sum by(name) (rate(container_fs_reads_bytes_total{name=~"kyb-infra-.*"}[1m]))` |
| Disk Write | Time series (stacked) | `sum by(name) (rate(container_fs_writes_bytes_total{name=~"kyb-infra-.*"}[1m]))` |
| Disk Usage (overlay) | Time series | `container_fs_usage_bytes{name=~"kyb-infra-.*", device=~"/dev/sd.*"}` |

### Dashboard Variables

| Variable | Type | Definition |
|----------|------|------------|
| `$container` | Query (Prometheus) | `label_values(container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}, name)` |
| `$metric_type` | Custom | `cpu`, `memory`, `network`, `disk` |

All time-series panels should use `$container` as a filter to drill into a single container.

### Dashboard: Single Container Detail

**Name:** `Infra / Containers / [Container Name] Detail`
**Repeat for:** Each `$container`

Provides the same panels as the overview but pre-filtered to one container, with additional details:
- CPU steal time (if applicable)
- Memory breakdown: RSS vs cache vs swap
- Network by interface (eth0 vs veth*)
- Disk I/O queue depth
- OOM timeline

## 8. Alerting Rules

### 8.1 Prometheus Alerting Rules

Create `infra/prometheus/alerts.yml`:

```yaml
groups:
  - name: container-resources
    interval: 30s
    rules:
      - alert: ContainerHighCPU
        expr: |
          sum by(name) (rate(container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}[5m]))
          /
          sum by(name) (container_spec_cpu_quota{name=~"kyb-infra-.*"})
          > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: 'Container {{ $labels.name }} CPU usage > 80% for 5m'

      - alert: ContainerHighMemory
        expr: |
          container_memory_working_set_bytes{name=~"kyb-infra-.*"}
          /
          container_spec_memory_limit_bytes{name=~"kyb-infra-.*"}
          > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: 'Container {{ $labels.name }} memory usage > 85%'

      - alert: ContainerOOM
        expr: |
          increase(container_oom_events_total{name=~"kyb-infra-.*"}[5m]) > 0
        labels:
          severity: critical
        annotations:
          summary: 'Container {{ $labels.name }} OOM killed'

      - alert: ContainerCPUThrottling
        expr: |
          sum by(name) (rate(container_cpu_cfs_throttled_periods_total{name=~"kyb-infra-.*"}[5m]))
          /
          sum by(name) (rate(container_cpu_cfs_periods_total{name=~"kyb-infra-.*"}[5m]))
          > 0.2
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: 'Container {{ $labels.name }} throttled >20% of CPU time'

      - alert: ContainerDiskFull
        expr: |
          container_fs_usage_bytes{name=~"kyb-infra-.*"}
          /
          container_fs_limit_bytes{name=~"kyb-infra-.*"}
          > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: 'Container {{ $labels.name }} disk usage > 90%'

      - alert: ContainerNetworkErrors
        expr: |
          rate(container_network_receive_errors_total{name=~"kyb-infra-.*"}[5m])
          + rate(container_network_transmit_errors_total{name=~"kyb-infra-.*"}[5m])
          > 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: 'Container {{ $labels.name }} network errors detected'

      - alert: CAdvisorDown
        expr: up{job="cadvisor"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: 'cAdvisor is down (no metrics for 1m)'
```

### 8.2 Patrol Integration

The existing 5-min patrol can also check cAdvisor health:

```bash
# In patrol check.docker step
curl -sf http://kyb-infra-cadvisor:8080/healthz > /dev/null \
  && echo "cadvisor: ok" \
  || echo "cadvisor: DOWN"
```

## 9. Container for cAdvisor and Prometheus

### Volumes

```bash
# Create persistent volumes
docker volume create prometheus-data
docker volume create vector-data
```

### Network Connectivity

All containers on `kyb-net`. Verify:

```bash
docker exec kyb-infra-prometheus wget -qO- http://kyb-infra-cadvisor:8080/metrics | head
docker exec kyb-infra-grafana wget -qO- http://kyb-infra-prometheus:9090/api/v1/status/tsdb | head
```

If Grafana cannot resolve container names by DNS, use `/etc/hosts` entries or ensure `kyb-net` has embedded DNS (Docker's default bridge network does; `kyb-net` created via `docker network create kyb-net` does).

## 10. Implementation Roadmap

### Phase 1: Foundation (Day 1)

- [ ] Deploy cAdvisor container (`kyb-infra-cadvisor`)
- [ ] Verify `/metrics` endpoint responds: `curl http://localhost:8080/metrics | head -50`
- [ ] Verify cAdvisor health: `curl http://localhost:8080/healthz`
- [ ] Deploy Prometheus container with config
- [ ] Verify Prometheus target up: `curl http://localhost:9090/api/v1/targets`

### Phase 2: Grafana Integration (Day 1)

- [ ] Provision Prometheus datasource in Grafana
- [ ] Build `Container Resource Overview` dashboard
- [ ] Build `Single Container Detail` dashboard
- [ ] Verify panels return data

### Phase 3: ClickHouse Long-Term Storage (Day 2)

- [ ] Deploy Vector container
- [ ] Create `monitor.container_metrics` table in ClickHouse
- [ ] Deploy Vector config: cAdvisor scrape → CK sink
- [ ] Verify data in CK: `SELECT count() FROM monitor.container_metrics`
- [ ] Create hourly/daily rollup tables and MV
- [ ] Add CK-based Grafana panels (historical views)

### Phase 4: Alerting (Day 2)

- [ ] Deploy Prometheus alerting rules
- [ ] Integrate with notification channel (feishu/email)
- [ ] Add cAdvisor health check to 5-min patrol
- [ ] Test OOM alert by intentionally overcommitting a test container

### Phase 5: Polish (Day 3)

- [ ] Adjust scrape intervals based on actual series count
- [ ] Set Prometheus TSDB retention budget
- [ ] Tune CK TTL for rollups
- [ ] Write runbook entry (in `docs/infra/handbook/`)

## 11. Alternatives Considered

### 11.1 Docker Stats API (no cAdvisor)

```bash
docker stats --no-stream --format '{{json .}}'
```

Simple but no persistent output, no historical data, and no integration with Prometheus/ClickHouse. Only useful for ad-hoc debugging.

### 11.2 Telegraf + InfluxDB

Telegraf has a Docker input plugin that collects container stats and can write to InfluxDB. Rejected because:
- Adds another database (InfluxDB) to the stack
- InfluxDB does not integrate with existing ClickHouse + Grafana setup
- Telegraf config is more complex than cAdvisor

### 11.3 Prometheus Node Exporter + cAdvisor

Node Exporter provides host-level metrics (CPU, memory, disk, network). It is not a replacement for cAdvisor (no per-container metrics), but is a **complement**. Consider deploying if host-level visibility is needed:

```bash
docker run -d \
  --name kyb-infra-node-exporter \
  --network kyb-net \
  --restart unless-stopped \
  -p 9100:9100 \
  -v /proc:/host/proc:ro \
  -v /sys:/host/sys:ro \
  -v /:/rootfs:ro \
  prom/node-exporter:v1.7.0 \
  --path.procfs=/host/proc \
  --path.sysfs=/host/sys \
  --path.rootfs=/rootfs
```

**Decision:** Out of scope for this design. Add only if host-level metrics become necessary.

### 11.4 Docker Desktop / Portainer

GUI tools for container management. Provide live stats but no programmable API, no historical data export, and no integration with the observability stack. Not suitable.

### 11.5 Direct Docker SDK Integration

Write a custom Go/Ruby script that polls Docker API `/containers/{id}/stats` and writes to ClickHouse. Feasible but duplicates cAdvisor functionality. cAdvisor is battle-tested (Google, 100M+ deployments), handles edge cases (container restarts, label changes, cgroup v1/v2), and is less maintenance.

## 12. Known Issues and Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| cAdvisor cgroup v2 incompatibility | Medium | No metrics | cAdvisor v0.49+ supports cgroup v2; test on this kernel |
| Prometheus TSDB fills disk | Low | Data loss, query failures | Set `--storage.tsdb.retention.size=10GB` cap |
| Vector prometheus_scrape parsing fails | Low | Missing CK data | Monitor Vector logs; fallback to prom2click |
| cAdvisor privileged mode security concern | High | Container breakout risk | cAdvisor runs read-only mounts; `--security-opt=no-new-privileges` |
| High series cardinality from container labels | Low | Prometheus memory usage | Relabel config drops unnecessary labels |

## Appendix A: Quick Deploy Script

```bash
#!/bin/bash
# deploy-cadvisor.sh: Deploy cAdvisor + Prometheus for container monitoring

set -euo pipefail

NETWORK="kyb-net"

echo "=== Creating volumes ==="
docker volume create prometheus-data 2>/dev/null || true

echo "=== Deploying cAdvisor ==="
docker run -d \
  --name kyb-infra-cadvisor \
  --network "$NETWORK" \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /sys:/sys:ro \
  -v /var/lib/docker/:/var/lib/docker:ro \
  -v /dev/disk/:/dev/disk:ro \
  -v /etc/machine-id:/etc/machine-id:ro \
  --privileged \
  gcr.io/cadvisor/cadvisor:v0.49.1 \
  -docker_only=true \
  -housekeeping_interval=10s \
  -max_housekeeping_interval=30s \
  -global_housekeeping_interval=60s

echo "=== Deploying Prometheus ==="
# Ensure config dir exists
mkdir -p "$(dirname "$0")/../infra/prometheus"

docker run -d \
  --name kyb-infra-prometheus \
  --network "$NETWORK" \
  --restart unless-stopped \
  -p 9090:9090 \
  -v prometheus-data:/prometheus \
  -v "$(realpath "$(dirname "$0")/../infra/prometheus/prometheus.yml")":/etc/prometheus/prometheus.yml:ro \
  prom/prometheus:v2.53.0 \
  --storage.tsdb.retention.time=15d \
  --storage.tsdb.retention.size=10GB

echo "=== Verifying ==="
sleep 3
curl -sf http://localhost:8080/healthz > /dev/null && echo "cAdvisor: OK" || echo "cAdvisor: FAIL"
curl -sf http://localhost:9090/api/v1/targets > /dev/null && echo "Prometheus: OK" || echo "Prometheus: FAIL"

echo "=== Done ==="
```

## Appendix B: Key PromQL Queries

```promql
# CPU usage per container (cores, last 5m avg)
sum by(name) (rate(container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}[5m]))

# Memory working set vs limit (%)
container_memory_working_set_bytes{name=~"kyb-infra-.*"}
  / on(name) container_spec_memory_limit_bytes{name=~"kyb-infra-.*"}
  * 100

# Network throughput (bytes/sec)
sum by(name) (rate(container_network_receive_bytes_total{name=~"kyb-infra-.*"}[1m]))

# Disk I/O (bytes/sec, read+write)
sum by(name) (rate(container_fs_reads_bytes_total{name=~"kyb-infra-.*"}[1m])
            + rate(container_fs_writes_bytes_total{name=~"kyb-infra-.*"}[1m]))

# OOM events in last 24h
sum by(name) (increase(container_oom_events_total{name=~"kyb-infra-.*"}[24h]))

# CPU throttle ratio
sum by(name) (rate(container_cpu_cfs_throttled_periods_total{name=~"kyb-infra-.*"}[5m]))
  / sum by(name) (rate(container_cpu_cfs_periods_total{name=~"kyb-infra-.*"}[5m]))
```

## Appendix C: ClickHouse Queries for Historical Analysis

```sql
-- Average CPU usage per container over last 7 days (from CK)
SELECT
    container_name,
    avg_val AS avg_cpu_seconds_per_second,
    p95_val AS p95_cpu_seconds_per_second
FROM monitor.container_metrics_hourly
WHERE metric_name = 'container_cpu_usage_seconds_total'
  AND event_hour >= now() - INTERVAL 7 DAY
  AND metric_type = 'counter'
ORDER BY container_name;

-- Top 5 containers by memory (peak in last 30 days)
SELECT
    container_name,
    max(max_val) AS peak_memory_bytes,
    formatReadableSize(max(max_val)) AS peak_memory_readable,
    argMax(event_hour, max_val) AS peak_time
FROM monitor.container_metrics_hourly
WHERE metric_name = 'container_memory_working_set_bytes'
  AND event_hour >= now() - INTERVAL 30 DAY
GROUP BY container_name
ORDER BY peak_memory_bytes DESC
LIMIT 5;

-- Network traffic trend (daily, last 90 days)
SELECT
    toDate(event_hour) AS day,
    container_name,
    sum(max_val - min_val) AS total_bytes
FROM monitor.container_metrics_hourly
WHERE metric_name = 'container_network_receive_bytes_total'
  AND event_hour >= now() - INTERVAL 90 DAY
GROUP BY day, container_name
ORDER BY day, container_name;

-- Disk usage growth over time (weekly)
SELECT
    toStartOfWeek(event_hour) AS week,
    container_name,
    avg(avg_val) AS avg_bytes,
    formatReadableSize(avg(avg_val)) AS avg_readable
FROM monitor.container_metrics_hourly
WHERE metric_name = 'container_fs_usage_bytes'
  AND event_hour >= now() - INTERVAL 90 DAY
GROUP BY week, container_name
ORDER BY week, container_name;
```

## Appendix D: Related Documents

- Observability architecture overview: `docs/infra/observability-design.md`
- Bridge metrics & logging (similar Prometheus → CK pattern): `docs/infra/designs/bridge-metrics-logging.md`
- Review of bridge metrics design: `docs/infra/reviews/review-bridge-metrics-B2.md`
- CK query monitoring (Grafana + ClickHouse pattern reference): `docs/infra/reviews/ck-query-monitor.md`
- Pat tool integration (for patrol health checks): `docs/infra/reviews/otel-patrol.md`
