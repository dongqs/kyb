---
decision: 稍后做
---

# Prometheus Scraping for All Infra Services

**Status:** Design Document
**Date:** 2026-05-23
**Context:** Unified Prometheus-based metrics collection across all infrastructure clusters (Mac/Orbstack, Aliyun, Office), covering cc-connect, containers, and boss-level metrics.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prometheus Deployment](#2-prometheus-deployment)
3. [Scrape Targets](#3-scrape-targets)
4. [Cross-Cluster Scraping](#4-cross-cluster-scraping)
5. [cc-connect Metrics Exposition](#5-cc-connect-metrics-exposition)
6. [Container Metrics](#6-container-metrics)
7. [Boss Metrics](#7-boss-metrics)
8. [Alerting Rules](#8-alerting-rules)
9. [Grafana Integration](#9-grafana-integration)
10. [Operational Runbook](#10-operational-runbook)
11. [Migration Plan](#11-migration-plan)

---

## 1. Architecture Overview

### 1.1 Current State

- Grafana runs on Mac/Orbstack (`kyb-infra-grafana`), connected to ClickHouse.
- Heartbeats go directly from each boss to ClickHouse via HTTP POST (shell loops).
- No Prometheus exists yet. No node-level or container-level metrics are collected.
- No alerting pipeline exists (reboot detection, disk full, process death all manual).

### 1.2 Target State

```
                          ┌──────────────────────────────────────────────┐
                          │              Mac / Orbstack                  │
                          │                                              │
                          │  ┌──────────┐   ┌──────────┐   ┌─────────┐  │
                          │  │ cc-connect│   │ cadvisor  │   │ node_   │  │
                          │  │ :9091    │   │ :8080     │   │ exporter│  │
                          │  └─────┬────┘   └─────┬────┘   │ :9100   │  │
                          │        │              │        └────┬────┘  │
                          │  ┌─────┴──────────────┴─────────────┴────┐  │
                          │  │            Prometheus                  │  │
                          │  │            :9090                      │  │
                          │  └─────┬──────────────┬─────────────┬────┘  │
                          │        │              │             │       │
                          │  ┌─────┴────┐   ┌─────┴────┐  ┌────┴────┐ │
                          │  │ Grafana  │   │Alert-    │  │ClickHouse│ │
                          │  │ :3000    │   │manager   │  │ :8123    │ │
                          │  └──────────┘   │ :9093    │  └─────────┘ │
                          │                 └──────────┘               │
                          └────────────────────────────────────────────┘
                                          │
                          ┌───────────────┼───────────────┐
                          │               │               │
              ┌───────────▼──────┐  ┌─────▼───────────┐  ┌▼──────────────┐
              │  Aliyun / sim   │  │  Office / nuc8   │  │  Volcano (TBD) │
              │  Tailscale       │  │  Tailscale       │  │  Tailscale     │
              │  100.113.24.32   │  │  100.98.29.39    │  │  TBD           │
              ├─────────────────┤  ├──────────────────┤  ├───────────────┤
              │ node_exporter   │  │ node_exporter    │  │ node_exporter  │
              │ cadvisor        │  │ cadvisor         │  │ cadvisor       │
              │ ACR mirror      │  │ proxy-exit       │  │ CI runners     │
              │ OSS cache       │  │ GitLab mirror    │  │ K8s            │
              │ build runners   │  │ Nexus cache      │  │ DERP relay     │
              └─────────────────┘  └──────────────────┘  └───────────────┘
```

### 1.3 Data Flow

| Data | Source | Transport | Destination | Purpose |
|------|--------|-----------|-------------|---------|
| Heartbeat metrics | Boss shell loop | HTTP POST | ClickHouse | Persistence, historical |
| App metrics | cc-connect :9091 | Prometheus scrape | Prometheus | Real-time, alerting |
| Container metrics | cadvisor :8080 | Prometheus scrape | Prometheus | Resource monitoring |
| Host metrics | node_exporter :9100 | Prometheus scrape | Prometheus | Host health |
| Alert events | Prometheus Alertmanager | Webhook | Feishu (via cc-connect) | Real-time notification |

**Design rationale:** ClickHouse stays as the long-term metrics archive (heartbeats with 60s granularity). Prometheus handles the high-frequency scrape data (15s granularity) and drives alerting. Grafana queries both sources -- Prometheus for real-time dashboards, ClickHouse for historical trends.

---

## 2. Prometheus Deployment

### 2.1 Container Setup

```bash
# Create persistent volume
docker volume create kyb-infra-prometheus-data

# Create config directory
mkdir -p ~/.kyb/prometheus

# Run Prometheus
docker run -d \
  --name kyb-infra-prometheus \
  --restart unless-stopped \
  --network kyb-net \
  -p 9090:9090 \
  -v ~/.kyb/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
  -v ~/.kyb/prometheus/rules:/etc/prometheus/rules:ro \
  -v kyb-infra-prometheus-data:/prometheus \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.retention.time=30d \
  --storage.tsdb.retention.size=10GB

# Run Alertmanager
mkdir -p ~/.kyb/prometheus/alertmanager

docker run -d \
  --name kyb-infra-alertmanager \
  --restart unless-stopped \
  --network kyb-net \
  -p 9093:9093 \
  -v ~/.kyb/prometheus/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro \
  prom/alertmanager:latest
```

### 2.2 Network

Both Prometheus and Alertmanager join `kyb-net` (the kyb-managed Docker network), giving them:
- Direct DNS resolution to all kyb containers (cc-connect, Grafana, Kafka, PG, etc.)
- Access to the Docker socket host for service discovery (if needed)

Tailscale IPs are reachable from within containers via the host's Tailscale routes (confirmed working per architecture doc -- Orbstack forwards Tailscale to containers).

### 2.3 Storage

- **Retention:** 30 days or 10 GB, whichever is hit first
- **Volume:** Docker volume (`kyb-infra-prometheus-data`), survives container restarts
- **No high-availability:** Single instance is adequate at this scale (<10k time series). If Prometheus goes down, scrape data is lost but the gap is bounded by retention policy.

### 2.4 Resource Estimates

| Component | CPU | Memory | Disk | Network |
|-----------|-----|--------|------|---------|
| Prometheus | 0.1-0.5 core | ~256 MB | ~2-5 GB over 30 days | Minimal |
| Alertmanager | <0.1 core | ~64 MB | Negligible | Minimal |
| cadvisor | 0.1-0.3 core | ~100 MB | Negligible | Minimal |
| node_exporter | <0.05 core | ~30 MB | Negligible | Minimal |
| PG/Redis/Kafka exporters | <0.05 core each | ~30 MB each | Negligible | Minimal |

Total additional load on Mac/Orbstack: ~0.5-1.0 CPU, ~500 MB RAM. Negligible for modern hardware.

---

## 3. Scrape Targets

### 3.1 Prometheus Configuration

File: `~/.kyb/prometheus/prometheus.yml`

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: mac-orbstack

# Scrape configurations are split into per-source files for maintainability
scrape_config_files:
  - "/etc/prometheus/rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - kyb-infra-alertmanager:9093

rule_files:
  - "/etc/prometheus/rules/alerts.yml"
```

### 3.2 Per-Service Scrape Configs

#### 3.2.1 cc-connect (application metrics)

File: `~/.kyb/prometheus/scrape_cc_connect.yml`

```yaml
scrape_configs:
  - job_name: "cc-connect"
    static_configs:
      - targets:
          - "kyb-infra-cc-connect:9091"  # container on kyb-net
    metrics_path: /metrics
    scrape_interval: 15s
    # cc-connect emits metrics at /metrics via a Prometheus Ruby client
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: "cc-connect"
```

**Expected metrics series (from cc-connect, ~20-30 time series):**

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `cc_messages_received_total` | Counter | chat_type | Total messages received from Feishu |
| `cc_messages_processed_total` | Counter | status (success/error/timeout) | Messages processed by Claude |
| `cc_messages_sent_total` | Counter | chat_type | Messages sent back to Feishu |
| `cc_turn_duration_seconds` | Histogram | - | Per-turn latency, buckets 0.1-300s |
| `cc_tokens_per_turn` | Histogram | direction (input/output) | Token consumption buckets |
| `cc_errors_total` | Counter | error_type | Error breakdown by type |
| `cc_active_sessions` | Gauge | - | Currently active sessions |
| `cc_up` | Gauge | - | 1 if cc-connect is healthy, 0 otherwise |
| `up` | Gauge | instance, job | Prometheus built-in reachability |

**cc-connect metrics endpoint** is served by a small HTTP server embedded in cc-connect (port 9091, path `/metrics`). See [Section 5](#5-cc-connect-metrics-exposition) for implementation details.

#### 3.2.2 cadvisor (Docker container metrics)

File: `~/.kyb/prometheus/scrape_cadvisor.yml`

```yaml
scrape_configs:
  - job_name: "cadvisor"
    static_configs:
      - targets:
          - "cadvisor:8080"  # local on Mac/Orbstack
          - "100.113.24.32:8080"  # Aliyun sim
          - "100.98.29.39:8080"   # Office nuc8
    metrics_path: /metrics
    scrape_interval: 30s  # container metrics are less volatile
    relabel_configs:
      - source_labels: [__address__]
        regex: "cadvisor:8080"
        target_label: cluster
        replacement: "mac-orbstack"
      - source_labels: [__address__]
        regex: "100.113.24.32:8080"
        target_label: cluster
        replacement: "aliyun"
      - source_labels: [__address__]
        regex: "100.98.29.39:8080"
        target_label: cluster
        replacement: "office"
```

**Key cadvisor metrics for alerting:**
- `container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}`
- `container_memory_working_set_bytes{name=~"kyb-infra-.*"}`
- `container_network_receive_bytes_total{name=~"kyb-infra-.*"}`
- `container_fs_usage_bytes{name=~"kyb-infra-.*"}`

#### 3.2.3 node_exporter (host metrics)

File: `~/.kyb/prometheus/scrape_node_exporter.yml`

```yaml
scrape_configs:
  - job_name: "node"
    static_configs:
      - targets:
          - "10.0.0.1:9100"       # Mac/Orbstack host
          - "100.113.24.32:9100"   # Aliyun sim
          - "100.98.29.39:9100"    # Office nuc8
    metrics_path: /metrics
    scrape_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        regex: "10.0.0.1:9100"
        target_label: cluster
        replacement: "mac-orbstack"
      - source_labels: [__address__]
        regex: "100.113.24.32:9100"
        target_label: cluster
        replacement: "aliyun"
      - source_labels: [__address__]
        regex: "100.98.29.39:9100"
        target_label: cluster
        replacement: "office"
```

**Note on Mac/Orbstack node_exporter:** Orbstack runs Docker in a Linux VM, so `node_exporter` needs to run on the macOS host natively (not in Docker) to get true host metrics. Install via Homebrew:

```bash
brew install node_exporter
brew services start node_exporter
```

On Aliyun and Office (Linux hosts), run node_exporter as a Docker container:

```bash
docker run -d \
  --name node_exporter \
  --restart unless-stopped \
  --network host \
  --pid host \
  -v /:/host:ro,rslave \
  prom/node-exporter:latest \
  --path.rootfs=/host
```

#### 3.2.4 Database & Service Exporters

##### PostgreSQL (one per version)

File: `~/.kyb/prometheus/scrape_pg_exporter.yml`

```yaml
scrape_configs:
  - job_name: "postgresql"
    static_configs:
      - targets:
          - "kyb-infra-postgresql-exporter-14:9187"
          - "kyb-infra-postgresql-exporter-15:9187"
          - "kyb-infra-postgresql-exporter-16:9187"
          - "kyb-infra-postgresql-exporter-17:9187"
    metrics_path: /metrics
    scrape_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        regex: ".*-(\\d+):9187"
        target_label: pg_version
        replacement: "$1"
```

PG exporter setup per version:

```bash
for v in 14 15 16 17; do
  docker run -d \
    --name kyb-infra-postgresql-exporter-${v} \
    --restart unless-stopped \
    --network kyb-net \
    -e DATA_SOURCE_NAME="postgresql://postgres:postgres@kyb-infra-postgresql-${v}:5432/postgres?sslmode=disable" \
    prometheuscommunity/postgres-exporter:latest
done
```

##### Redis

```yaml
scrape_configs:
  - job_name: "redis"
    static_configs:
      - targets:
          - "kyb-infra-redis-exporter:9121"
    scrape_interval: 30s
```

```bash
docker run -d \
  --name kyb-infra-redis-exporter \
  --restart unless-stopped \
  --network kyb-net \
  -e REDIS_ADDR=redis://kyb-infra-redis:6379 \
  oliver006/redis_exporter:latest
```

##### Kafka

```yaml
scrape_configs:
  - job_name: "kafka"
    static_configs:
      - targets:
          - "kyb-infra-kafka-exporter:9308"
    scrape_interval: 30s
```

```bash
docker run -d \
  --name kyb-infra-kafka-exporter \
  --restart unless-stopped \
  --network kyb-net \
  danielqsj/kafka-exporter:latest \
  --kafka.server=kyb-infra-kafka:9092
```

##### ClickHouse

```yaml
scrape_configs:
  - job_name: "clickhouse"
    static_configs:
      - targets:
          - "kyb-infra-clickhouse-exporter:9116"
    scrape_interval: 30s
```

```bash
docker run -d \
  --name kyb-infra-clickhouse-exporter \
  --restart unless-stopped \
  --network kyb-net \
  -e CLICKHOUSE_DSN="clickhouse://kyb-infra-clickhouse:8123/default" \
  prometheuscommunity/clickhouse-exporter:latest
```

#### 3.2.5 sing-box Proxy

```yaml
scrape_configs:
  - job_name: "sing-box"
    static_configs:
      - targets:
          - "kyb-infra-sing-box:9091"  # sing-box metrics endpoint
    metrics_path: /metrics
    scrape_interval: 30s
```

sing-box can expose Prometheus metrics when configured with an `experimental` section:

```json
{
  "experimental": {
    "metrics": {
      "addr": "0.0.0.0:9091",
      "path": "/metrics"
    }
  }
}
```

### 3.3 Scrape Config Organization

All config files stored in `~/.kyb/prometheus/` and mounted into Prometheus:

```bash
~/.kyb/prometheus/
├── prometheus.yml              # global config, alertmanager ref
├── alertmanager/
│   └── alertmanager.yml        # alert routing to Feishu
├── rules/
│   └── alerts.yml              # alerting rules
└── scrape_*.yml                # per-service scrape configs
```

Prometheus can load multiple config files using `scrape_config_files` (v2.27+). Alternatively, for older versions, concatenate all scrape configs into `prometheus.yml`:

```bash
# Generate combined config
cat ~/.kyb/prometheus/prometheus.yml \
  ~/.kyb/prometheus/scrape_cc_connect.yml \
  ~/.kyb/prometheus/scrape_cadvisor.yml \
  ~/.kyb/prometheus/scrape_node_exporter.yml \
  ~/.kyb/prometheus/scrape_pg_exporter.yml \
  > ~/.kyb/prometheus/_combined.yml
```

### 3.4 Total Time Series Estimate

| Job | Time Series (estimated) |
|-----|------------------------|
| cc-connect | ~30 (11 base metrics + buckets + labels) |
| cadvisor | ~200 (all infra containers x resource types) |
| node_exporter | ~500 (3 nodes x ~160 series each) |
| PG exporters | ~200 (4 PG instances) |
| Redis exporter | ~50 |
| Kafka exporter | ~100 |
| ClickHouse exporter | ~80 |
| Prometheus self | ~30 |
| sing-box | ~20 |
| **Total** | **~1,210 time series** |

Well within the capacity of a single Prometheus instance (typical limit: 500k-1M time series).

---

## 4. Cross-Cluster Scraping

### 4.1 Approach: Central Prometheus, Remote Scraping

A single Prometheus instance on Mac/Orbstack scrapes all targets across all clusters. Remote targets (Aliyun, Office, future Volcano) are reached via Tailscale IPs.

**Why not per-cluster Prometheus:**
- Higher operational overhead (N instances to maintain, N configs)
- Remote write complexity (each instance needs to push to central storage or be federated)
- At current scale (<2000 time series total), network scraping is reliable and simpler

**Why this works:**
- Tailscale routes are reachable from within Docker containers on Mac/Orbstack (confirmed in architecture doc)
- Scrape failures are gracefully handled (Prometheus retries, marks as stale, doesn't block other scrapes)
- Latency is acceptable (Tailscale direct connections: 8-12ms between nodes)

### 4.2 Target Reachability Matrix

```
Prometheus -> Aliyun (sim):
  cadvisor:      100.113.24.32:8080     Reachable via Tailscale
  node_exporter: 100.113.24.32:9100     Reachable via Tailscale
  build-runner:  100.113.24.32:9091     (if exposed, optional)

Prometheus -> Office (nuc8):
  cadvisor:      100.98.29.39:8080      Reachable via Tailscale (relay if CGNAT)
  node_exporter: 100.98.29.39:9100      Reachable via Tailscale (relay if CGNAT)
  nexus:         100.98.29.39:9091      (if exposed, optional)
```

### 4.3 Verifying Reachability

```bash
# From within the Prometheus container or any kyb container:
docker exec kyb-infra-prometheus -- sh -c "
  wget -qO- http://100.113.24.32:9100/metrics | head -5
  wget -qO- http://100.98.29.39:8080/metrics | head -5
"
```

If Tailscale routing is not working inside containers, fall back to the host bridge:

```bash
# Alternative: use host network for Prometheus
docker run -d --network host ...
# Then reach Tailscale IPs directly from the host namespace
```

### 4.4 Remote Cluster Setup

For each cluster (Aliyun, Office), run these containers on the host:

```bash
# On Aliyun (sim):
# 1. Node exporter
ssh sim "docker run -d --name node_exporter --restart unless-stopped --network host --pid host -v /:/host:ro,rslave prom/node-exporter:latest --path.rootfs=/host"

# 2. Cadvisor
ssh sim "docker run -d --name cadvisor --restart unless-stopped --network host -v /var/run/docker.sock:/var/run/docker.sock:ro -v /:/rootfs:ro -v /var/run:/var/run:ro -v /sys:/sys:ro -v /etc/machine-id:/etc/machine-id:ro gcr.io/cadvisor/cadvisor:latest"

# Same commands on Office (nuc8), but use Tailscale IP 100.98.29.39
ssh nuc8 "docker run -d --name node_exporter ..."
ssh nuc8 "docker run -d --name cadvisor ..."
```

---

## 5. cc-connect Metrics Exposition

### 5.1 Metrics Endpoint

cc-connect runs an embedded Prometheus HTTP server on port 9091, serving `/metrics`. This is a lightweight Ruby WEBrick or Puma server colocated within the cc-connect process -- no sidecar needed.

The cc-connect binary already has a structure that emits structured logs. Adding Prometheus metrics follows the same instrumentation pattern:

### 5.2 Metrics Implementation Plan

**Ruby side (cc-connect, which is a Ruby process):**

```ruby
# Gemfile addition
gem 'prometheus-client'

# config/metrics.rb
require 'prometheus/client'

module Metrics
  def self.registry
    @registry ||= Prometheus::Client.registry
  end

  # Counters
  def self.messages_received
    @messages_received ||= registry.counter(
      :cc_messages_received_total,
      docstring: 'Total messages received from Feishu',
      labels: [:chat_type]
    )
  end

  def self.messages_processed
    @messages_processed ||= registry.counter(
      :cc_messages_processed_total,
      docstring: 'Messages processed by Claude',
      labels: [:status]
    )
  end

  def self.errors_total
    @errors_total ||= registry.counter(
      :cc_errors_total,
      docstring: 'Error count by type',
      labels: [:error_type]
    )
  end

  # Histograms
  def self.turn_duration
    @turn_duration ||= registry.histogram(
      :cc_turn_duration_seconds,
      docstring: 'Per-turn latency in seconds',
      buckets: [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300]
    )
  end

  def self.tokens_per_turn
    @tokens_per_turn ||= registry.histogram(
      :cc_tokens_per_turn,
      docstring: 'Token consumption per turn',
      labels: [:direction],
      buckets: [1, 50, 100, 500, 1000, 2000, 4000, 8000, 16000]
    )
  end

  # Gauges
  def self.active_sessions
    @active_sessions ||= registry.gauge(
      :cc_active_sessions,
      docstring: 'Currently active Claude sessions'
    )
  end
end
```

**Metrics server (colocated in cc-connect process):**

```ruby
# server/metrics_server.rb
require 'webrick'
require 'prometheus/client/rack/exporter'

module MetricsServer
  def self.start(port: 9091)
    server = WEBrick::HTTPServer.new(
      Port: port,
      Logger: WEBrick::Log.new('/dev/null'),
      AccessLog: []
    )
    server.mount '/metrics', Prometheus::Client::Rack::Exporter
    Thread.new { server.start }
  end
end
```

**Instrumentation points in cc-connect:**

```ruby
# At each key lifecycle point:
# 1. Message received from Feishu
Metrics.messages_received.increment(labels: { chat_type: chat_type })

# 2. Error encountered
Metrics.errors_total.increment(labels: { error_type: error.class.name })

# 3. Claude response complete
Metrics.turn_duration.observe(duration_seconds)
Metrics.tokens_per_turn.observe(tokens_input, labels: { direction: 'input' })
Metrics.tokens_per_turn.observe(tokens_output, labels: { direction: 'output' })
Metrics.messages_processed.increment(labels: { status: 'success' })

# 4. Session lifecycle
Metrics.active_sessions.set(current_sessions_count)
```

### 5.3 Instrumentation Points vs Hook Points

The metrics above correspond to the hook points defined in `docs/infra/designs/bridge-hooks-alerting.md`:

| Hook Point | Metrics | Alert Trigger |
|------------|---------|---------------|
| Message received | `cc_messages_received_total++` | - |
| Claude response | `cc_turn_duration.observe()`, `cc_messages_processed_total++` | Duration >30s |
| Timeout | `cc_errors_total{error_type="timeout"}++` | Aggregate rate |
| Crash/error | `cc_errors_total{error_type="crash"}++` | Container unhealthy |
| Session recovery | `cc_active_sessions` gauge adjusts | - |
| Permissions request | - | Duration >10min (handled by patrol) |

### 5.4 Health Check Integration

cc-connect's existing health check (`cc-healthcheck`) already verifies:
- Container is running (`docker inspect`)
- Docker health status (`healthy` or not)
- Feishu API token valid

The health endpoint (`GET /health`) can emit a synthetic metric:

```ruby
get '/health' do
  healthy = check_health
  Metrics.cc_up.set(healthy ? 1 : 0)
  status(healthy ? 200 : 503)
end
```

---

## 6. Container Metrics

### 6.1 cadvisor Deployment

cadvisor runs on each cluster host as a Docker container:

```bash
# On each host (Mac/Orbstack, Aliyun, Office):
docker run -d \
  --name cadvisor \
  --restart unless-stopped \
  --network kyb-net \
  --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /:/rootfs:ro \
  -v /var/run:/var/run:ro \
  -v /sys:/sys:ro \
  -v /etc/machine-id:/etc/machine-id:ro \
  gcr.io/cadvisor/cadvisor:latest
```

**Note on Mac/Orbstack:** Orbstack does not expose the full Docker filesystem through `/var/lib/docker`. cadvisor will still work for container lifecycle and resource metrics (CPU, memory, network) but may report incomplete filesystem metrics. This is acceptable -- host-level disk monitoring is handled by node_exporter.

### 6.2 Key Metrics for Alerting

| Metric | Expression | Description |
|--------|-----------|-------------|
| Container CPU | `rate(container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}[1m])` | CPU usage per container |
| Container memory | `container_memory_working_set_bytes{name=~"kyb-infra-.*"}` | RSS memory per container |
| Container network | `rate(container_network_receive_bytes_total{name=~"kyb-infra-.*"}[1m])` | Network receive rate |
| Container disk | `container_fs_usage_bytes{name=~"kyb-infra-.*"}` | Filesystem usage per container |
| Container restarts | `rate(container_last_seen{name=~"kyb-infra-.*"}[5m])` == 0 | Container death detection |

### 6.3 Docker Event Monitoring

For real-time container lifecycle events (create, destroy, start, stop, die), cadvisor alone is not sufficient. Two approaches:

**Approach A (Recommended): Docker Events via Prometheus**

Deploy a small Docker event exporter that watches the Docker socket and emits Prometheus metrics:

```bash
# Use docker-events-exporter or write a minimal one
docker run -d \
  --name kyb-infra-docker-events \
  --restart unless-stopped \
  --network kyb-net \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  mercu/docker-events-exporter:latest
```

This exposes:
- `docker_events_total{type="container", action="die|stop|start|create|destroy"}` -- Counter
- `docker_container_state{name, state="running|exited|paused"}` -- Gauge (1/0)

**Approach B (Minimal): Boss shell loop (current)**

The heartbeat script already tracks `docker ps -q | wc -l` and `docker ps -aq | wc -l`. This gives per-cluster aggregate container counts but no per-container detail.

**Recommendation:** Use Approach A for real-time events + per-container visibility. Keep Approach B's heartbeat for cross-cluster aggregate health.

---

## 7. Boss Metrics

### 7.1 Current Boss Heartbeat (Keep)

The existing heartbeat protocol (shell loop -> ClickHouse POST every 60s) continues to run. It provides:
- Cross-cluster heartbeat health (was the boss running at T-60s?)
- Aggregate container counts (running vs total)
- Disk and memory utilization
- Historical trend data in ClickHouse

### 7.2 New Boss Exporter (Prometheus)

In addition to the heartbeat, each boss container runs a small metrics exporter exposing real-time boss state:

File: `~/kyb/boss_exporter.rb` (runs inside the boss container)

```ruby
require 'webrick'
require 'json'

# Exposes boss state as a minimal /metrics endpoint
# Runs as a background thread in the boss container

module BossExporter
  PORT = 9101

  def self.collect_metrics
    {
      boss_up: 1,
      boss_uptime_seconds: (Time.now - BOOT_TIME).to_i,
      docker_containers_running: `docker ps -q`.lines.count,
      docker_containers_total: `docker ps -aq`.lines.count,
      disk_used_percent: `df / | tail -1`.split[4].to_i,
      memory_used_percent: `free | grep Mem | awk '{print $3/$2 * 100}'`.strip.to_f,
      load_1: File.read('/proc/loadavg').split[0].to_f,
      load_5: File.read('/proc/loadavg').split[1].to_f,
      load_15: File.read('/proc/loadavg').split[2].to_f,
    }
  end

  def self.serve(port: PORT)
    server = WEBrick::HTTPServer.new(
      Port: port,
      Logger: WEBrick::Log.new('/dev/null'),
      AccessLog: []
    )

    server.mount_proc '/health' do |req, res|
      res.body = 'OK'
      res.content_type = 'text/plain'
    end

    server.mount_proc '/metrics' do |req, res|
      metrics = collect_metrics
      body = metrics.map { |k, v| "#{k} #{v}" }.join("\n") + "\n"
      res.body = body
      res.content_type = 'text/plain; version=0.0.4'
    end

    Thread.new { server.start }
  end
end

BossExporter.serve
```

Prometheus scrape config for boss exporters:

```yaml
scrape_configs:
  - job_name: "boss"
    static_configs:
      - targets:
          - "kyb-infra-boss:9101"     # Mac/Orbstack
          - "100.113.24.32:9101"      # Aliyun (via Tailscale)
          - "100.98.29.39:9101"       # Office (via Tailscale)
    metrics_path: /metrics
    scrape_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        regex: "kyb-infra-boss:9101"
        target_label: boss_id
        replacement: "mac-boss"
      - source_labels: [__address__]
        regex: "100.113.24.32:9101"
        target_label: boss_id
        replacement: "aliyun-boss"
      - source_labels: [__address__]
        regex: "100.98.29.39:9101"
        target_label: boss_id
        replacement: "office-boss"
```

### 7.3 Agent Health Metrics

For sandbox agents (the kyb-created containers running Claude), track:

```yaml
scrape_configs:
  - job_name: "agents"
    cadvisor scrape # covered by cadvisor job above
```

Agent health is already covered by cadvisor (container-level CPU/memory/uptime). For code-level agent health (is Claude Code responsive?), the patrol system covers this via heartbeat file checks.

### 7.4 Metrics Comparison: Heartbeat vs Prometheus

| Aspect | Heartbeat (ClickHouse) | Prometheus Exporter |
|--------|----------------------|-------------------|
| Granularity | 60s | 15-30s |
| Storage | Persistent (retention: indefinite) | 30d or 10GB |
| Purpose | Historical analysis, long-term trends | Real-time dashboards, alerting |
| Transport | HTTP POST (curl) | Prometheus scrape |
| Coverage | 3 clusters | 3 clusters |
| Alerting | None (manual patrol) | Automated via Alertmanager |

Both coexist. The heartbeat provides the durable record; Prometheus provides the real-time view.

---

## 8. Alerting Rules

### 8.1 Alertmanager Configuration

File: `~/.kyb/prometheus/alertmanager/alertmanager.yml`

```yaml
global:
  resolve_timeout: 5m
  # No SMTP -- all alerts go to Feishu via webhook
  # The webhook receiver is a lightweight sidecar that POSTs to Feishu API

route:
  receiver: "feishu-default"
  group_by: ["alertname", "cluster"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - match:
        severity: "critical"
      receiver: "feishu-critical"
      repeat_interval: 30m
    - match:
        severity: "warning"
      receiver: "feishu-default"
      repeat_interval: 4h

receivers:
  - name: "feishu-default"
    webhook_configs:
      - url: "http://kyb-infra-cc-connect:9091/webhook/alert"
        send_resolved: true

  - name: "feishu-critical"
    webhook_configs:
      - url: "http://kyb-infra-cc-connect:9091/webhook/alert"
        send_resolved: true
        http_config:
          headers:
            X-Alert-Priority: "critical"
```

### 8.2 Alerting Rules

File: `~/.kyb/prometheus/rules/alerts.yml`

```yaml
groups:
  - name: infra_alerts
    interval: 30s
    rules:

      # ============================================================
      # cc-connect health
      # ============================================================
      - alert: CcConnectDown
        expr: up{job="cc-connect"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "cc-connect is down on {{ $labels.instance }}"
          description: "cc-connect has been unreachable for >1 minute. Feishu bridge is offline."
          runbook: "docker logs kyb-infra-cc-connect --tail 20 && docker restart kyb-infra-cc-connect"

      - alert: CcConnectHighErrorRate
        expr: rate(cc_errors_total[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "cc-connect error rate elevated"
          description: "Error rate on {{ $labels.instance }}: {{ $value | humanize }} errors/s over 5m"
          runbook: "docker logs kyb-infra-cc-connect --tail 50 | grep ERROR"

      - alert: CcConnectHighLatency
        expr: histogram_quantile(0.90, rate(cc_turn_duration_seconds_bucket[5m])) > 30
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "cc-connect P90 latency >30s"
          description: "P90 response latency: {{ $value }}s. Claude may be degraded."
          runbook: "Check Claude API status. docker logs kyb-infra-cc-connect --tail 20"

      - alert: CcConnectSustainedHighLatency
        expr: histogram_quantile(0.99, rate(cc_turn_duration_seconds_bucket[5m])) > 60
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "cc-connect P99 latency >60s"
          description: "P99 response latency: {{ $value }}s. Users are experiencing timeouts."
          runbook: "Urgent: check Claude API, network proxy, and cc-connect logs."

      # ============================================================
      # Host health (all clusters)
      # ============================================================
      - alert: HostDown
        expr: up{job="node"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Host {{ $labels.instance }} is unreachable"
          description: "Node exporter on {{ $labels.cluster }} has been unreachable for >2m."
          runbook: "ssh to the host and check: uptime, docker ps, tailscale status"

      - alert: DiskSpaceCritical
        expr: (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Disk >90% full on {{ $labels.cluster }}"
          description: "Disk usage: {{ $value | humanize }}%. Clean up or resize disk."
          runbook: "ssh {{ $labels.cluster }} 'df -h / && docker system prune -af'"

      - alert: DiskSpaceWarning
        expr: (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 > 80
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Disk >80% full on {{ $labels.cluster }}"
          description: "Disk usage: {{ $value | humanize }}%. Plan cleanup."

      - alert: HighMemoryUsage
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 90
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Memory >90% used on {{ $labels.cluster }}"
          description: "Memory usage: {{ $value | humanize }}%"

      - alert: HighLoadAverage
        expr: node_load15 / count(node_cpu_seconds_total{mode="idle"}) by (instance) > 0.8
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Load average high on {{ $labels.cluster }}"
          description: "15m load average: {{ $value }}"

      # ============================================================
      # Docker / Container health
      # ============================================================
      - alert: ContainerDown
        expr: time() - container_last_seen{name=~"kyb-infra-.*"} > 60
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Container {{ $labels.name }} is down"
          description: "{{ $labels.name }} on {{ $labels.cluster }} has not been seen for >2m."
          runbook: "Check container: docker ps -a --filter name={{ $labels.name }}"

      - alert: ContainerHighCPU
        expr: rate(container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}[5m]) > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Container {{ $labels.name }} CPU >90%"
          description: "{{ $labels.name }} on {{ $labels.cluster }}: {{ $value | humanize }} CPU cores"

      - alert: ContainerHighMemory
        expr: container_memory_working_set_bytes{name=~"kyb-infra-.*"} / 1024 / 1024 > 512
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Container {{ $labels.name }} memory >512MB"
          description: "{{ $labels.name }} on {{ $labels.cluster }}: {{ $value | humanize }} MB"

      - alert: ContainerRestartLoop
        expr: changes(container_start_time_seconds{name=~"kyb-infra-.*"}[15m]) > 3
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Container {{ $labels.name }} is restarting frequently"
          description: "{{ $labels.name }} restarted {{ $value }} times in 15m"

      # ============================================================
      # Boss health
      # ============================================================
      - alert: BossHeartbeatMissed
        expr: time() - boss_uptime_seconds{job="boss"} > 120
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.boss_id }} heartbeat missed"
          description: "Boss {{ $labels.boss_id }} has not reported for >2m. Cluster may be offline."
          runbook: "Check Tailscale connectivity and host status."

      - alert: BossDiskCritical
        expr: disk_used_percent{job="boss"} > 90
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.boss_id }} disk >90% full"
          description: "Boss {{ $labels.boss_id }} disk: {{ $value }}%"

      # ============================================================
      # Service-specific (PostgreSQL, Redis, Kafka, ClickHouse)
      # ============================================================
      - alert: PostgreSQLDown
        expr: pg_up{job="postgresql"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL {{ $labels.pg_version }} is down"
          description: "PG {{ $labels.pg_version }} on mac-orbstack is unreachable."

      - alert: RedisDown
        expr: redis_up{job="redis"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Redis is down"
          description: "Redis on mac-orbstack is unreachable."

      - alert: KafkaDown
        expr: up{job="kafka"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Kafka is down"
          description: "Kafka on mac-orbstack is unreachable."

      - alert: ClickHouseDown
        expr: clickhouse_up{job="clickhouse"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "ClickHouse is down"
          description: "ClickHouse on mac-orbstack is unreachable. All dashboards will be stale."

      # ============================================================
      # Prometheus self-health
      # ============================================================
      - alert: PrometheusTargetMissing
        expr: up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Scrape target {{ $labels.job }}/{{ $labels.instance }} is unreachable"
          description: "Prometheus cannot reach {{ $labels.instance }} (job: {{ $labels.job }})"

      - alert: PrometheusTSDBFull
        expr: prometheus_tsdb_storage_blocks_bytes / 10737418240 > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Prometheus TSDB approaching size limit"
          description: "TSDB storage: {{ $value | humanize }}% of 10GB limit"

      - alert: PrometheusHighScrapeFailures
        expr: rate(prometheus_target_scrapes_exceeded_sample_limit_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Prometheus scrape failures detected"
          description: "Some targets are exceeding scrape limits"
```

### 8.3 Alert Severity Definitions

| Severity | Meaning | Response Time | Channel |
|----------|---------|---------------|---------|
| `critical` | Service is down or data is being lost | 5 min | Feishu @user + repeat every 30m |
| `warning` | Degraded but still serving | 1 hour | Feishu group, repeat every 4h |
| `info` | Informational, no action needed | Next patrol | Patrol log |

### 8.4 Feishu Webhook Integration

Alerts reach Feishu through cc-connect's existing webhook endpoint. cc-connect already handles incoming webhooks -- adding a `/webhook/alert` endpoint that:

1. Receives the Alertmanager webhook JSON payload
2. Formats it as a Feishu message (text or post)
3. Sends to `kyb-kindergarden` group (the usual notification target)

Alertmanager webhook payload format:

```json
{
  "version": "4",
  "groupKey": "{}:{alertname=\"CcConnectDown\"}",
  "status": "firing",
  "receiver": "feishu-default",
  "groupLabels": { "alertname": "CcConnectDown" },
  "commonLabels": { "severity": "critical" },
  "commonAnnotations": {
    "summary": "cc-connect is down",
    "runbook": "docker logs kyb-infra-cc-connect --tail 20"
  },
  "alerts": [
    {
      "status": "firing",
      "labels": { "alertname": "CcConnectDown", "instance": "cc-connect" },
      "annotations": { "summary": "cc-connect is down" },
      "startsAt": "2026-05-23T10:00:00Z",
      "endsAt": "0001-01-01T00:00:00Z"
    }
  ]
}
```

---

## 9. Grafana Integration

### 9.1 Data Source

Add Prometheus as a Grafana data source (in addition to existing ClickHouse):

```bash
# Via Grafana API (or UI)
curl -X POST http://admin:admin@kyb-infra-grafana:3000/api/datasources \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "url": "http://kyb-infra-prometheus:9090",
    "access": "proxy",
    "isDefault": false
  }'
```

### 9.2 Dashboard: Infrastructure Overview

| Panel | Source | Query |
|-------|--------|-------|
| All containers (by cluster) | Prometheus | `count(container_last_seen{name=~"kyb-infra-.*"}) by (cluster)` |
| Container CPU top-N | Prometheus | `topk(10, rate(container_cpu_usage_seconds_total{name=~"kyb-infra-.*"}[5m]))` |
| Container memory top-N | Prometheus | `topk(10, container_memory_working_set_bytes{name=~"kyb-infra-.*"})` |
| Host disk utilization | Prometheus | `(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100` |
| Boss uptime | Prometheus | `boss_uptime_seconds` |
| Active alerts | Prometheus | `ALERTS{alertstate="firing"}` |

### 9.3 Dashboard: cc-connect Overview

| Panel | Source | Query |
|-------|--------|-------|
| Message throughput | Prometheus | `rate(cc_messages_received_total[5m])` + `rate(cc_messages_sent_total[5m])` |
| Latency P50/P90/P99 | Prometheus | `histogram_quantile(0.50/0.90/0.99, rate(cc_turn_duration_seconds_bucket[5m]))` |
| Error rate | Prometheus | `rate(cc_errors_total[5m])` |
| Active sessions | Prometheus | `cc_active_sessions` |
| Token consumption | Prometheus | `rate(cc_tokens_per_turn_sum[5m])` by direction |
| (Historical) Message log | ClickHouse | `SELECT * FROM cc.message_log` |

### 9.4 Dashboard: Cluster Health

| Panel | Source | Query |
|-------|--------|-------|
| Cross-cluster container health | Prometheus | `up{job="node"}` by cluster |
| Per-cluster container count | Prometheus | `docker_containers_running{job="boss"}` |
| Per-cluster disk usage | Prometheus | `disk_used_percent{job="boss"}` |
| Heartbeat table (last 24h) | ClickHouse | `SELECT * FROM boss_heartbeats WHERE timestamp > now() - 1 DAY` |

---

## 10. Operational Runbook

### 10.1 First-Time Setup (Mac/Orbstack)

```bash
# Step 1: Create config directories
mkdir -p ~/.kyb/prometheus/{alertmanager,rules}
mkdir -p ~/.kyb/prometheus/alertmanager

# Step 2: Write config files
#   prometheus.yml, scrape_*.yml, alerts.yml, alertmanager.yml

# Step 3: Create Docker volumes
docker volume create kyb-infra-prometheus-data

# Step 4: Start node_exporter on Mac host (not in Docker)
brew install node_exporter
brew services start node_exporter

# Step 5: Start cadvisor locally
docker run -d \
  --name cadvisor \
  --restart unless-stopped \
  --network kyb-net \
  --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /:/rootfs:ro \
  -v /var/run:/var/run:ro \
  -v /sys:/sys:ro \
  -v /etc/machine-id:/etc/machine-id:ro \
  gcr.io/cadvisor/cadvisor:latest

# Step 6: Start service exporters (PG, Redis, Kafka, ClickHouse)
#   (commands in Section 3.2.4)

# Step 7: Start Prometheus
docker run -d \
  --name kyb-infra-prometheus \
  --restart unless-stopped \
  --network kyb-net \
  -p 9090:9090 \
  -v ~/.kyb/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
  -v ~/.kyb/prometheus/rules:/etc/prometheus/rules:ro \
  -v kyb-infra-prometheus-data:/prometheus \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.retention.time=30d \
  --storage.tsdb.retention.size=10GB

# Step 8: Start Alertmanager
docker run -d \
  --name kyb-infra-alertmanager \
  --restart unless-stopped \
  --network kyb-net \
  -p 9093:9093 \
  -v ~/.kyb/prometheus/alertmanager:/etc/alertmanager:ro \
  prom/alertmanager:latest

# Step 9: Add Prometheus data source in Grafana (UI or API)

# Step 10: Import dashboards
```

### 10.2 Remote Cluster Setup (Aliyun / Office)

```bash
# For each remote cluster:

# Step 1: Node exporter (Linux hosts only)
dispatch aliyun "docker run -d --name node_exporter ..."
dispatch office "docker run -d --name node_exporter ..."

# Step 2: Cadvisor
dispatch aliyun "docker run -d --name cadvisor ..."
dispatch office "docker run -d --name cadvisor ..."

# Step 3: Boss exporter (runs inside boss container, start on next boss restart)
#   Add BossExporter.serve to boss startup script

# Step 4: Verify Prometheus can scrape from Mac
docker exec kyb-infra-prometheus wget -qO- http://100.113.24.32:9100/metrics | head
docker exec kyb-infra-prometheus wget -qO- http://100.98.29.39:9100/metrics | head
```

### 10.3 Prometheus Config Reload

```bash
# Reload config without restarting Prometheus
kill -HUP $(docker exec kyb-infra-prometheus pidof prometheus)
# Or use the reload endpoint (if --web.enable-lifecycle is set)
curl -X POST http://localhost:9090/-/reload
```

Add `--web.enable-lifecycle` to the Prometheus startup command for HTTP reload capability.

### 10.4 Verification Checklist

```
[ ] Prometheus UI reachable: http://localhost:9090/targets (all targets UP)
[ ] Alertmanager UI reachable: http://localhost:9093
[ ] Grafana data source connected: Prometheus datasource green
[ ] cc-connect metrics visible: query cc_messages_received_total
[ ] cadvisor metrics visible: query container_cpu_usage_seconds_total
[ ] node_exporter metrics visible: query node_filesystem_size_bytes
[ ] Remote scrapes working: check aliyun/office targets are UP
[ ] Boss exporter metrics visible: query boss_uptime_seconds
[ ] Alert test: silence then trigger CcConnectDown intentionally
[ ] Feishu webhook: verify alert message appears in kyb-kindergarden
```

### 10.5 Backup and Recovery

Prometheus data is on a Docker volume (`kyb-infra-prometheus-data`). For backup:

```bash
# Snapshot the Prometheus data directory
docker run --rm \
  -v kyb-infra-prometheus-data:/data:ro \
  -v ~/backups:/backup \
  alpine \
  tar czf /backup/prometheus-$(date +%Y%m%d).tar.gz -C /data .
```

To restore:

```bash
docker run --rm \
  -v kyb-infra-prometheus-data:/data \
  -v ~/backups:/backup:ro \
  alpine \
  tar xzf /backup/prometheus-20260523.tar.gz -C /data
```

---

## 11. Migration Plan

### 11.1 Phase 1: Local Setup (Day 1)

**Deploy Prometheus + Alertmanager on Mac/Orbstack.**
- [ ] Create config files
- [ ] Start Prometheus container
- [ ] Start Alertmanager container
- [ ] Configure Feishu webhook integration
- [ ] Verify Grafana data source
- [ ] Test with self-scraping only

**Effort:** 1 hour. Owner: infra-boss.

### 11.2 Phase 2: cc-connect Instrumentation (Day 1-2)

**Add Prometheus metrics endpoint to cc-connect.**
- [ ] Add prometheus-client gem
- [ ] Implement Metrics module
- [ ] Add /metrics endpoint
- [ ] Instrument lifecycle points
- [ ] Write scrape config
- [ ] Verify metrics in Prometheus

**Effort:** 2 hours. Owner: cc-connect maintainer.

### 11.3 Phase 3: Local Exporters (Day 2)

**Deploy cadvisor + node_exporter + service exporters on Mac/Orbstack.**
- [ ] Install node_exporter (brew)
- [ ] Deploy cadvisor container
- [ ] Deploy PG/Redis/Kafka/ClickHouse exporters
- [ ] Write scrape configs
- [ ] Verify all targets UP

**Effort:** 1 hour. Owner: infra-boss.

### 11.4 Phase 4: Remote Clusters (Day 2-3)

**Deploy node_exporter + cadvisor on Aliyun and Office.**
- [ ] SSH and deploy exporters on Aliyun
- [ ] SSH and deploy exporters on Office
- [ ] Boss exporter inside boss containers
- [ ] Verify reachability from central Prometheus
- [ ] Write remote cluster scrape configs

**Effort:** 1 hour. Owner: infra-boss (via SSH dispatch).

### 11.5 Phase 5: Alerting (Day 2-3)

**Enable alerting rules, test, iterate.**
- [ ] Write alerting rules file
- [ ] Configure Alertmanager routing
- [ ] Verify Feishu notifications
- [ ] Test each alert level
- [ ] Tune thresholds based on baseline data

**Effort:** 1 hour. Owner: infra-boss.

### 11.6 Phase 6: Dashboards (Day 3)

**Build Grafana dashboards.**
- [ ] Infrastructure overview dashboard
- [ ] cc-connect overview dashboard
- [ ] Cluster health dashboard
- [ ] Alert dashboard

**Effort:** 2 hours. Owner: infra-boss.

### 11.7 Rollback Plan

If Prometheus causes issues (resource contention, false alerts):

```bash
# Stop Prometheus and Alertmanager
docker stop kyb-infra-prometheus kyb-infra-alertmanager
docker rm kyb-infra-prometheus kyb-infra-alertmanager

# Remove exporters
docker stop cadvisor kyb-infra-postgresql-exporter-* kyb-infra-redis-exporter kyb-infra-kafka-exporter kyb-infra-clickhouse-exporter
docker rm cadvisor kyb-infra-postgresql-exporter-* kyb-infra-redis-exporter kyb-infra-kafka-exporter kyb-infra-clickhouse-exporter

# Grafana continues to work (connected to ClickHouse only)
# Feishu continues to work
# cc-connect continues to work
# Everything degrades gracefully to pre-Prometheus state
```

No service depends on Prometheus. It is a monitoring-only component. Rollback is safe at any point.

---

## Appendix A: Prometheus Configuration Checklist

| Item | File | Purpose |
|------|------|---------|
| Global config | `prometheus.yml` | scrape_interval, evaluation_interval, external_labels |
| Alertmanager ref | `prometheus.yml` | alerting.alertmanagers |
| Alert rules | `rules/alerts.yml` | All alerting rules |
| Alertmanager config | `alertmanager/alertmanager.yml` | Routing, receivers, webhook |
| Scrape: cc-connect | `scrape_cc_connect.yml` | Application metrics |
| Scrape: cadvisor | `scrape_cadvisor.yml` | Container metrics |
| Scrape: node_exporter | `scrape_node_exporter.yml` | Host metrics |
| Scrape: PG exporters | `scrape_pg_exporter.yml` | PostgreSQL metrics |
| Scrape: Redis | `scrape_redis_exporter.yml` | Redis metrics |
| Scrape: Kafka | `scrape_kafka_exporter.yml` | Kafka metrics |
| Scrape: ClickHouse | `scrape_clickhouse_exporter.yml` | ClickHouse metrics |
| Scrape: Boss | `scrape_boss_exporter.yml` | Boss health metrics |
| Scrape: sing-box | `scrape_singbox.yml` | Proxy metrics |

## Appendix B: Port Allocation

| Port | Service | Description |
|------|---------|-------------|
| 9090 | Prometheus | Prometheus UI + API |
| 9091 | cc-connect | cc-connect Prometheus metrics |
| 9091 | sing-box | sing-box Prometheus metrics (same port, different network) |
| 9093 | Alertmanager | Alertmanager UI + API |
| 9100 | node_exporter | Host metrics (all hosts) |
| 9101 | Boss exporter | Boss container metrics |
| 8080 | cadvisor | Container metrics (all hosts) |
| 9121 | Redis exporter | Redis metrics |
| 9187 | PG exporter (x4) | PostgreSQL metrics (one per version) |
| 9308 | Kafka exporter | Kafka metrics |
| 9116 | ClickHouse exporter | ClickHouse metrics |

## Appendix C: Alert Escalation Path

```
1. Alert fires
   │
   ├── severity=critical ──────────────────────────────────────────────┐
   │   ├── Feishu notification to kyb-kindergarden                     │
   │   ├── Repeat every 30 minutes                                     │
   │   └── Auto-remediation: cc-connect restart, disk cleanup          │
   │                                                                   │
   ├── severity=warning ───────────────────────────────────────────────┤
   │   ├── Feishu notification to kyb-kindergarden                     │
   │   ├── Repeat every 4 hours                                        │
   │   └── Auto-remediation: none (needs human assessment)             │
   │                                                                   │
   └── No active alerts ───────────────────────────────────────────────┘
       └── Patrol: "All clear" message (every 5 min during active hours)
```

> **Summary:** Single Prometheus instance on Mac/Orbstack scrapes all targets (local + remote via Tailscale). cc-connect exposes application metrics on :9091. cadvisor and node_exporter provide container + host metrics per cluster. Boss exporters fill the gap for boss-level health. Alertmanager routes all alerts to Feishu via cc-connect's webhook. Total time series: ~1,200, well within single-instance capacity. Six-phase rollout: 1-2 days total effort.

> ／人◕ ‿‿ ◕人＼
