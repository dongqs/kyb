---
decision: 稍后做
---

# SLO Tracking for Infra Services

> **Status:** Design Document
> **Date:** 2026-05-23
> **Context:** Implement uptime SLO tracking, burn rate alerts, error budget monitoring, and a unified SLO dashboard across all infra clusters.

**See also:**
- `docs/infra/reviews/error-budget.md` -- Error budget policy, SLO tier definitions, budget depletion actions
- `docs/infra/reviews/prometheus-scrape.md` -- Prometheus deployment, scrape configs, alert routing
- `docs/infra/multi-cluster-boss-architecture.md` -- Multi-cluster architecture, boss hierarchy

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Uptime SLO per Service](#2-uptime-slo-per-service)
3. [SLI Probe Definitions](#3-sli-probe-definitions)
4. [Prometheus Recording Rules](#4-prometheus-recording-rules)
5. [Burn Rate Alert Rules](#5-burn-rate-alert-rules)
6. [Error Budget Tracking](#6-error-budget-tracking)
7. [SLO Dashboard](#7-slo-dashboard)
8. [Multi-Cluster Aggregation](#8-multi-cluster-aggregation)
9. [Alert Routing & Escalation](#9-alert-routing--escalation)
10. [Implementation Plan](#10-implementation-plan)
11. [Operational Runbook](#11-operational-runbook)

---

## 1. Architecture

### 1.1 Data Flow

```
Service (container)  ──scrape 15s──>  Prometheus (central)
                                         │
                                    ┌────┴────┐
                                    │         │
                               Recording    Alert
                                Rules     Manager
                                    │         │
                                    ▼         ▼
                               Grafana    Feishu (via
                              Dashboards  cc-connect webhook)
```

Prometheus on Mac/Orbstack scrapes all services every 15s. Recording rules compute SLO metrics (good/total events, burn rates, budget remaining) every 60s. Alertmanager evaluates burn rate thresholds. Grafana queries Prometheus for real-time SLO dashboards.

Cross-cluster services (Aliyun, Office) are scraped via Tailscale IPs from the central Prometheus.

### 1.2 Component Responsibilities

| Component | Role in SLO Tracking |
|-----------|---------------------|
| **Prometheus** | Scrape health probes, compute recording rules (SLO metrics), evaluate alert rules |
| **Alertmanager** | Route burn rate alerts to Feishu via cc-connect webhook |
| **Grafana** | SLO dashboard: budget remaining, burn rate heatmap, compliance gauges |
| **cc-connect** | Health endpoint for bridge uptime, alert webhook receiver |
| **Boss heartbeat** | Cross-cluster uptime signal (60s granularity, complements Prometheus) |
| **ClickHouse** | Long-term SLO history (error budget consumed per incident, monthly trend) |

### 1.3 Data Sources

Each service reports its health through one or more of these mechanisms:

| Mechanism | Granularity | Coverage | Used For |
|-----------|------------|----------|----------|
| Prometheus `up` metric | 15s | All scraped targets | Primary uptime SLI |
| Exporter health metrics | 15-30s | PG, Redis, Kafka, CK, sing-box | Request-level SLI |
| HTTP health endpoint | 15s (probe) | cc-connect, Grafana | App-level uptime SLI |
| Boss heartbeat | 60s | Process running, disk, load | Cross-cluster composite |
| Docker event stream | Real-time | Container lifecycle | Incident correlation |

---

## 2. Uptime SLO per Service

### 2.1 SLO Targets (summary from error-budget.md)

| Tier | Target | Budget (30d) | Example Services |
|------|--------|-------------|-----------------|
| 0 | 99.99% | 4m 19s | cc-connect |
| 1 | 99.9% | 43m 12s | PostgreSQL, ClickHouse, Redis, Kafka, feishu-bridge |
| 2 | 99.5% | 3h 35m | Vector, sing-box, ACR mirror, OSS cache |
| 3 | 99.0% | 7h 12m | Build runner, Grafana |

### 2.2 Service SLO Registry

Complete registry of all services, their SLO targets, SLI type, and probe details:

| Service | Cluster | SLO | SLI Type | Probe | Scrape Job |
|---------|---------|-----|----------|-------|-----------|
| cc-connect | mac-orbstack | 99.99% | Uptime (HTTP health) | `GET /health` → 200 | `cc-connect` |
| feishu-bridge | mac-orbstack | 99.9% | Uptime (process) | `up{job="feishu-bridge"}` | `feishu-bridge` |
| PostgreSQL-14 | mac-orbstack | 99.9% | Uptime + query success | `pg_up` + `pg_stat_database_xact_commit` | `postgresql` |
| PostgreSQL-15 | mac-orbstack | 99.9% | Uptime + query success | `pg_up` + commit ratio | `postgresql` |
| PostgreSQL-16 | mac-orbstack | 99.9% | Uptime + query success | `pg_up` + commit ratio | `postgresql` |
| PostgreSQL-17 | mac-orbstack | 99.9% | Uptime + query success | `pg_up` + commit ratio | `postgresql` |
| ClickHouse | mac-orbstack | 99.9% | Uptime + query latency | `clickhouse_up` + p99 < 1s | `clickhouse` |
| Redis | mac-orbstack | 99.9% | Uptime (PING) | `redis_up` | `redis` |
| Kafka | mac-orbstack | 99.9% | Uptime + produce | `kafka_broker_up` + produce success | `kafka` |
| Vector | mac-orbstack | 99.5% | Throughput | p95 delivery delay < 60s | `vector` |
| Grafana | mac-orbstack | 99.0% | Uptime (HTTP) | `GET /api/health` → 200 | `grafana` |
| sing-box | mac-orbstack | 99.5% | Uptime + conn success | `up` + success rate > 0.95 | `sing-box` |
| ACR mirror | aliyun | 99.5% | Pull success | registry pull success rate > 0.995 | `acr-mirror` |
| OSS cache | aliyun | 99.5% | Cache + fetch success | cache hit + upstream success | `oss-cache` |
| Build runner | aliyun | 99.0% | Job success | runner job success > 0.99 | `build-runner` |
| feishu-bridge (sync) | office | 99.5% | Sync job success | sync completion rate | `feishu-bridge-sync` |

### 2.3 Composite SLOs

| Journey | Components | Composite SLO | Budget (30d) |
|---------|-----------|---------------|-------------|
| Send message | cc-connect x PostgreSQL x sing-box | 99.88% | ~1m 2s |
| Receive response | cc-connect x Claude API | 99.9% | 43m 12s |
| View Grafana dashboard | Grafana x ClickHouse x PostgreSQL | 98.9% | ~15h |
| Docker pull via mirror | ACR mirror x sing-box | 99.0% | 7h 12m |

Composite SLO = product of individual SLIs (availability is multiplicative). Composite budget is tracked in a dedicated Grafana panel but does NOT trigger alerts -- individual service alerts fire first.

### 2.4 Uptime Definition per Service

"Up" means different things for different services:

**Tier-0 (cc-connect):**
- Process is running AND health endpoint returns 200
- Health endpoint checks: Feishu API token valid, Claude API reachable, WebSocket connected
- Down if any of these checks fail for >15s

**Tier-1 (databases):**
- Process is running AND accepting connections
- PostgreSQL: `pg_up == 1` AND transaction commit rate > 0 queries/min
- ClickHouse: `clickhouse_up == 1` AND query latency p99 < 1s
- Redis: `redis_up == 1` AND PING responds within 100ms
- Kafka: broker `up == 1` AND produce latency p99 < 500ms

**Tier-2 (infrastructure):**
- Process is running AND primary function succeeds
- Vector: consuming log events AND delivering >95% within 60s
- sing-box: proxy tunnel open AND connection success rate > 95%

**Tier-3 (tooling):**
- Process is running (basic uptime)
- Grafana: HTTP 200 on /api/health
- Build runner: registered with GitLab AND accepting jobs

---

## 3. SLI Probe Definitions

### 3.1 Prometheus Probe Targets

#### cc-connect (Tier-0)

```yaml
# Prometheus scrape config
scrape_configs:
  - job_name: "cc-connect"
    static_configs:
      - targets: ["kyb-infra-cc-connect:9091"]
    metrics_path: /health
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: service
        replacement: "cc-connect"
```

cc-connect's `/health` endpoint:
```ruby
# In cc-connect server
get '/health' do
  healthy = cc_connected? && feishu_token_valid? && claude_api_reachable?
  if healthy
    content_type :json
    { status: 'ok', uptime_seconds: (Time.now - BOOT_TIME).to_i }.to_json
  else
    halt 503, { status: 'degraded', checks: health_checks }.to_json
  end
end
```

The `cc_connect_up` synthetic metric:
```ruby
# In /metrics endpoint (port 9091)
cc_connect_up.set(healthy ? 1 : 0)
```

#### PostgreSQL (Tier-1)

```yaml
scrape_configs:
  - job_name: "postgresql"
    static_configs:
      - targets:
          - "kyb-infra-postgresql-exporter-14:9187"
          - "kyb-infra-postgresql-exporter-15:9187"
          - "kyb-infra-postgresql-exporter-16:9187"
          - "kyb-infra-postgresql-exporter-17:9187"
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        regex: ".*-(\\d+):9187"
        target_label: pg_version
        replacement: "$1"
      - source_labels: [__address__]
        target_label: service
        regex: ".*-(\\d+):9187"
        replacement: "postgresql-$1"
```

SLI metrics:
```sql
-- Good = server is up AND transactions are committing
pg_up == 1
AND rate(pg_stat_database_xact_commit{datname!~"template.*"}[5m]) > 0
```

#### ClickHouse (Tier-1)

```yaml
scrape_configs:
  - job_name: "clickhouse"
    static_configs:
      - targets: ["kyb-infra-clickhouse-exporter:9116"]
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: service
        replacement: "clickhouse"
```

SLI metrics:
```sql
-- Good = up AND p99 query latency < 1s
clickhouse_up == 1
AND histogram_quantile(0.99, rate(clickhouse_query_duration_seconds_bucket[5m])) < 1.0
```

#### Redis (Tier-1)

```yaml
scrape_configs:
  - job_name: "redis"
    static_configs:
      - targets: ["kyb-infra-redis-exporter:9121"]
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: service
        replacement: "redis"
```

SLI metrics:
```sql
-- Good = up AND PING responds
redis_up == 1
```

#### Kafka (Tier-1)

```yaml
scrape_configs:
  - job_name: "kafka"
    static_configs:
      - targets: ["kyb-infra-kafka-exporter:9308"]
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: service
        replacement: "kafka"
```

SLI metrics:
```sql
-- Good = broker up AND produce requests succeeding
kafka_broker_up == 1
AND rate(kafka_produce_total{status="success"}[5m]) / rate(kafka_produce_total[5m]) > 0.99
```

#### Vector (Tier-2)

```yaml
scrape_configs:
  - job_name: "vector"
    static_configs:
      - targets: ["kyb-infra-vector:9090"]
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: service
        replacement: "vector"
```

SLI metrics:
```sql
-- Good = p95 delivery delay < 60s
vector_delivery_delay_seconds{quantile="0.95"} < 60
```

#### sing-box (Tier-2)

```yaml
scrape_configs:
  - job_name: "sing-box"
    static_configs:
      - targets: ["kyb-infra-sing-box:9091"]
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: service
        replacement: "sing-box"
```

SLI metrics:
```sql
-- Good = up AND connection success rate > 95%
sing_box_up == 1
AND rate(sing_box_connection_total{status="success"}[5m]) / rate(sing_box_connection_total[5m]) > 0.95
```

#### Grafana (Tier-3)

```yaml
scrape_configs:
  - job_name: "grafana"
    static_configs:
      - targets: ["kyb-infra-grafana:3000"]
    metrics_path: /api/health
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: service
        replacement: "grafana"
```

SLI metrics:
```sql
-- Good = API health endpoint returns 200
code{job="grafana"} == 200
-- OR use the synthetic up metric
up{job="grafana"} == 1
```

#### Remote Cluster Services (Tier-2/3)

For services on Aliyun and Office, the same pattern applies but scraped via Tailscale:

```yaml
scrape_configs:
  # ACR mirror (Aliyun)
  - job_name: "acr-mirror"
    static_configs:
      - targets: ["100.113.24.32:9092"]
    scrape_interval: 30s
    relabel_configs:
      - target_label: service
        replacement: "acr-mirror"
      - target_label: cluster
        replacement: "aliyun"

  # Build runner (Aliyun)
  - job_name: "build-runner"
    static_configs:
      - targets: ["100.113.24.32:9093"]
    scrape_interval: 30s
    relabel_configs:
      - target_label: service
        replacement: "build-runner"
      - target_label: cluster
        replacement: "aliyun"

  # Office services (Tailscale)
  - job_name: "feishu-bridge-sync"
    static_configs:
      - targets: ["100.98.29.39:9091"]
    scrape_interval: 30s
    relabel_configs:
      - target_label: service
        replacement: "feishu-bridge-sync"
      - target_label: cluster
        replacement: "office"
```

### 3.2 SLI Metric Naming Convention

Every service exports two synthetic metrics used for SLO computation:

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `sli_good_total` | Counter | `service`, `cluster` | Count of good events (up + healthy) |
| `sli_valid_total` | Counter | `service`, `cluster` | Count of total events (all scrapes) |

These are NOT emitted by the service itself. They are produced by **Prometheus recording rules** using the raw scrape metrics (see Section 4).

### 3.3 Synthetic Probes for Non-Metrics Services

For services that do not natively expose Prometheus metrics (e.g., ACR mirror, OSS cache, GitLab mirror), use **blackbox probes**:

```yaml
scrape_configs:
  - job_name: "blackbox"
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - "https://registry.cn-shanghai.aliyuncs.com/v2/"  # ACR
          - "https://oss-cn-shanghai.aliyuncs.com/"           # OSS
          - "https://git.leyantech.com/"                      # GitLab mirror
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "kyb-infra-blackbox-exporter:9115"

blackbox_exporter:
  - docker run -d \
      --name kyb-infra-blackbox-exporter \
      --restart unless-stopped \
      --network kyb-net \
      prom/blackbox-exporter:latest
```

For internal-only services without a public endpoint, use **TCP probes**:

```yaml
params:
  module: [tcp_connect]
static_configs:
  - targets:
      - "kyb-infra-postgresql-16:5432"
      - "kyb-infra-redis:6379"
      - "kyb-infra-kafka:9092"
      - "kyb-infra-clickhouse:8123"
```

---

## 4. Prometheus Recording Rules

### 4.1 Rule File Structure

```
~/.kyb/prometheus/rules/
├── slo-recording.yml          # SLO recording rules (this section)
├── slo-alerts.yml             # Burn rate alerts (Section 5)
└── alerts.yml                 # Existing infra alerts (from prometheus-scrape.md)
```

### 4.2 SLO Recording Rules

File: `~/.kyb/prometheus/rules/slo-recording.yml`

```yaml
groups:
  - name: slo_recording
    interval: 60s  # Evaluate every 60s (matches scrape interval x4)

    rules:
      # ====================================================
      # SLI: Good events per service (counter)
      # ====================================================

      # cc-connect: good = up == 1 (health endpoint reachable)
      - record: sli_good:cc_connect:total
        expr: |
          sum(up{job="cc-connect"} == 1) by (service, cluster)

      # PostgreSQL: good = up AND transactions committing
      - record: sli_good:postgresql:total
        expr: |
          sum(
            (pg_up == 1)
            AND on(instance)
            (rate(pg_stat_database_xact_commit{datname!~"template.*"}[5m]) > 0)
          ) by (service, cluster)

      # ClickHouse: good = up AND p99 latency < 1s
      - record: sli_good:clickhouse:total
        expr: |
          sum(
            (clickhouse_up == 1)
            AND on(instance)
            (histogram_quantile(0.99, rate(clickhouse_query_duration_seconds_bucket[5m])) < 1.0)
          ) by (service, cluster)

      # Redis: good = up
      - record: sli_good:redis:total
        expr: |
          sum(redis_up == 1) by (service, cluster)

      # Kafka: good = broker up AND produce success rate > 0.99
      - record: sli_good:kafka:total
        expr: |
          sum(
            (kafka_broker_up == 1)
            AND on(instance)
            (rate(kafka_produce_total{status="success"}[5m]) / rate(kafka_produce_total[5m]) > 0.99)
          ) by (service, cluster)

      # Vector: good = p95 delivery delay < 60s
      - record: sli_good:vector:total
        expr: |
          sum(
            vector_delivery_delay_seconds{quantile="0.95"} < 60
          ) by (service, cluster)

      # sing-box: good = up AND connection success rate > 95%
      - record: sli_good:sing_box:total
        expr: |
          sum(
            (sing_box_up == 1)
            AND on(instance)
            (rate(sing_box_connection_total{status="success"}[5m]) / rate(sing_box_connection_total[5m]) > 0.95)
          ) by (service, cluster)

      # Grafana: good = up
      - record: sli_good:grafana:total
        expr: |
          sum(up{job="grafana"} == 1) by (service, cluster)

      # Blackbox HTTP probes: good = probe_success == 1
      - record: sli_good:blackbox:total
        expr: |
          sum(probe_success == 1) by (service, cluster)

      # ====================================================
      # SLI: Total valid events per service (counter)
      # ====================================================

      # For uptime-based SLIs, total = count of scrapes = up metric always present
      - record: sli_valid:cc_connect:total
        expr: |
          count(up{job="cc-connect"}) by (service, cluster)

      - record: sli_valid:postgresql:total
        expr: |
          count(pg_up) by (service, cluster)

      - record: sli_valid:clickhouse:total
        expr: |
          count(clickhouse_up) by (service, cluster)

      - record: sli_valid:redis:total
        expr: |
          count(redis_up) by (service, cluster)

      - record: sli_valid:kafka:total
        expr: |
          count(kafka_broker_up) by (service, cluster)

      - record: sli_valid:vector:total
        expr: |
          count(vector_delivery_delay_seconds) by (service, cluster)

      - record: sli_valid:sing_box:total
        expr: |
          count(sing_box_up) by (service, cluster)

      - record: sli_valid:grafana:total
        expr: |
          count(up{job="grafana"}) by (service, cluster)

      - record: sli_valid:blackbox:total
        expr: |
          count(probe_success) by (service, cluster)
```

### 4.3 Unified SLO Metrics

For convenience, aggregate all services into a single metric pair using a rule that copies the per-service metrics into a common label set:

```yaml
      # ====================================================
      # Unified good/valid counters (for dashboard queries)
      # ====================================================

      - record: sli_good_total
        expr: |
          sli_good:cc_connect:total
          or sli_good:postgresql:total
          or sli_good:clickhouse:total
          or sli_good:redis:total
          or sli_good:kafka:total
          or sli_good:vector:total
          or sli_good:sing_box:total
          or sli_good:grafana:total
          or sli_good:blackbox:total

      - record: sli_valid_total
        expr: |
          sli_valid:cc_connect:total
          or sli_valid:postgresql:total
          or sli_valid:clickhouse:total
          or sli_valid:redis:total
          or sli_valid:kafka:total
          or sli_valid:vector:total
          or sli_valid:sing_box:total
          or sli_valid:grafana:total
          or sli_valid:blackbox:total
```

> **Note:** The per-service recording rules above are necessary because each service has a different definition of "good." The unified metric is a convenience for dashboard queries. In production, the per-service metrics (`sli_good:${service}:total`) are the source of truth.

### 4.4 SLO Compliance Recording Rules

Compute rolling window availability and error budget metrics:

```yaml
      # ====================================================
      # SLO Compliance (rolling window)
      # ====================================================

      # 30-day rolling availability
      - record: slo:availability:30d
        expr: |
          sum(rate(sli_good_total[30d])) by (service, cluster)
          /
          sum(rate(sli_valid_total[30d])) by (service, cluster)

      # 7-day rolling availability
      - record: slo:availability:7d
        expr: |
          sum(rate(sli_good_total[7d])) by (service, cluster)
          /
          sum(rate(sli_valid_total[7d])) by (service, cluster)

      # 1-day rolling availability
      - record: slo:availability:1d
        expr: |
          sum(rate(sli_good_total[1d])) by (service, cluster)
          /
          sum(rate(sli_valid_total[1d])) by (service, cluster)

      # ====================================================
      # Error Budget Remaining (0.0 to 1.0)
      # ====================================================

      # We need the SLO target as a label. Use a recording rule
      # that joins with the slo_target info metric.

      # First, define the SLO target per service as an info metric
      # This is typically done via a static config or file_sd
      - record: slo:target
        expr: |
          label_join(
            vector(0.9999)  # default, overridden by per-service rules
          )

      # Per-service SLO targets (constant)
      # cc-connect: 99.99% = 0.9999
      - record: slo:target:cc_connect
        expr: vector(0.9999)
      # Tier-1 services: 99.9% = 0.999
      - record: slo:target:postgresql
        expr: vector(0.999)
      - record: slo:target:clickhouse
        expr: vector(0.999)
      - record: slo:target:redis
        expr: vector(0.999)
      - record: slo:target:kafka
        expr: vector(0.999)
      # Tier-2 services: 99.5% = 0.995
      - record: slo:target:vector
        expr: vector(0.995)
      - record: slo:target:sing_box
        expr: vector(0.995)
      # Tier-3 services: 99.0% = 0.99
      - record: slo:target:grafana
        expr: vector(0.99)

      # Error budget remaining (simplified per-service computation)
      - record: slo:budget_remaining:ratio_30d
        expr: |
          clamp_min(
            1 - (
              (1 - slo:availability:30d)
              /
              0.001  # placeholder: replace with (1 - slo:target:{service})
            ),
            0
          )

      # For use in Grafana, compute budget remaining per service explicitly
      # cc-connect (99.99% SLO)
      - record: slo:budget_remaining:cc_connect:30d
        expr: |
          clamp_min(
            1 - (
              (1 - slo:availability:30d{service="cc-connect"})
              / (1 - 0.9999)
            ),
            0
          )

      # Tier-1 (99.9% SLO)
      - record: slo:budget_remaining:tier1:30d
        expr: |
          clamp_min(
            1 - (
              (1 - slo:availability:30d{service=~"postgresql|clickhouse|redis|kafka"})
              / (1 - 0.999)
            ),
            0
          )

      # Tier-2 (99.5% SLO)
      - record: slo:budget_remaining:tier2:30d
        expr: |
          clamp_min(
            1 - (
              (1 - slo:availability:30d{service=~"vector|sing_box"})
              / (1 - 0.995)
            ),
            0
          )

      # Tier-3 (99.0% SLO)
      - record: slo:budget_remaining:tier3:30d
        expr: |
          clamp_min(
            1 - (
              (1 - slo:availability:30d{service=~"grafana|build_runner"})
              / (1 - 0.99)
            ),
            0
          )

      # ====================================================
      # Burn Rate (instantaneous, over multiple windows)
      # ====================================================

      # Burn rate over 1h window
      - record: slo:burn_rate:1h
        expr: |
          (1 - sum(rate(sli_good_total[1h])) by (service) / sum(rate(sli_valid_total[1h])) by (service))
          /
          0.001  # placeholder: use the service's (1 - SLO)

      # Burn rate over 5m window (for short-window detection)
      - record: slo:burn_rate:5m
        expr: |
          (1 - sum(rate(sli_good_total[5m])) by (service) / sum(rate(sli_valid_total[5m])) by (service))
          /
          0.001

      # Burn rate over 6h window
      - record: slo:burn_rate:6h
        expr: |
          (1 - sum(rate(sli_good_total[6h])) by (service) / sum(rate(sli_valid_total[6h])) by (service))
          /
          0.001
```

### 4.5 Target Info Metric for SLO Lookup

For clean alert rules, define an info metric that carries the SLO target per service:

```yaml
      # Info metric for SLO targets (use in alert rules via group_left)
      - record: slo_target_info
        expr: |
          label_join(
            vector(0.9999), "service", "", "cc-connect"
          )
          or label_join(
            vector(0.999), "service", "", "postgresql"
          )
          or label_join(
            vector(0.999), "service", "", "clickhouse"
          )
          or label_join(
            vector(0.999), "service", "", "redis"
          )
          or label_join(
            vector(0.999), "service", "", "kafka"
          )
          or label_join(
            vector(0.995), "service", "", "vector"
          )
          or label_join(
            vector(0.995), "service", "", "sing_box"
          )
          or label_join(
            vector(0.99), "service", "", "grafana"
          )
        labels:
          # Re-apply 'service' label explicitly
```

---

## 5. Burn Rate Alert Rules

### 5.1 Multi-Window Multi-Burn-Rate (MWMBR)

Burn rate = how fast error budget is consumed relative to the SLO window. A burn rate of 1x means budget will last the full 30 days. A burn rate of 14x means budget will be exhausted in ~2 days.

**Alert windows:**

| Severity | Burn Rate | Short Window | Long Window | Time to Exhaust | Response |
|----------|-----------|-------------|-------------|-----------------|----------|
| P0 | >= 14x | 5m | 1h | < 2h | Page immediately |
| P1 | >= 6x | 30m | 6h | < 5h | Page within 15m |
| P2 | >= 2x | 6h | 3d | < 15d | Ticket, business hours |
| P3 | >= 1x | 1d | 30d | < 30d | Daily report |

### 5.2 Alert Rule Template

File: `~/.kyb/prometheus/rules/slo-alerts.yml`

```yaml
groups:
  - name: slo_alerts
    interval: 60s
    rules:

      # ====================================================
      # Tier-1 Alert Rules (99.9% SLO, 14x/6x/2x thresholds)
      # ====================================================

      # P0: 14x burn rate over 1h
      - alert: SloBudgetBurnP0_Tier1
        expr: |
          (
            (1 - sum(rate(sli_good_total{service=~"postgresql|clickhouse|redis|kafka"}[1h])) by (service)
               / sum(rate(sli_valid_total{service=~"postgresql|clickhouse|redis|kafka"}[1h])) by (service))
            > 14 * 0.001
          )
          and
          (
            (1 - sum(rate(sli_good_total{service=~"postgresql|clickhouse|redis|kafka"}[5m])) by (service)
               / sum(rate(sli_valid_total{service=~"postgresql|clickhouse|redis|kafka"}[5m])) by (service))
            > 14 * 0.001
          )
        for: 2m
        labels:
          severity: critical
          tier: "1"
        annotations:
          summary: "P0: {{ $labels.service }} burning budget at 14x rate"
          description: "Service {{ $labels.service }} consuming error budget at 14x rate. Budget will exhaust in ~3 days at this rate."
          runbook: "docs/infra/runbooks/p0-budget-burn.md"

      # P1: 6x burn rate over 6h
      - alert: SloBudgetBurnP1_Tier1
        expr: |
          (
            (1 - sum(rate(sli_good_total{service=~"postgresql|clickhouse|redis|kafka"}[6h])) by (service)
               / sum(rate(sli_valid_total{service=~"postgresql|clickhouse|redis|kafka"}[6h])) by (service))
            > 6 * 0.001
          )
          and
          (
            (1 - sum(rate(sli_good_total{service=~"postgresql|clickhouse|redis|kafka"}[30m])) by (service)
               / sum(rate(sli_valid_total{service=~"postgresql|clickhouse|redis|kafka"}[30m])) by (service))
            > 6 * 0.001
          )
        for: 5m
        labels:
          severity: warning
          tier: "1"
        annotations:
          summary: "P1: {{ $labels.service }} burning budget at 6x rate"
          description: "Service {{ $labels.service }} consuming error budget at 6x rate over 6h."

      # P2: 2x burn rate over 3d
      - alert: SloBudgetBurnP2_Tier1
        expr: |
          (
            (1 - sum(rate(sli_good_total{service=~"postgresql|clickhouse|redis|kafka"}[3d])) by (service)
               / sum(rate(sli_valid_total{service=~"postgresql|clickhouse|redis|kafka"}[3d])) by (service))
            > 2 * 0.001
          )
          and
          (
            (1 - sum(rate(sli_good_total{service=~"postgresql|clickhouse|redis|kafka"}[6h])) by (service)
               / sum(rate(sli_valid_total{service=~"postgresql|clickhouse|redis|kafka"}[6h])) by (service))
            > 2 * 0.001
          )
        for: 10m
        labels:
          severity: info
          tier: "1"
        annotations:
          summary: "P2: {{ $labels.service }} burning budget at 2x rate"
          description: "Service {{ $labels.service }} on track to exhaust budget in ~15 days."

      # ====================================================
      # Tier-0 Alert Rules (cc-connect, 99.99% SLO)
      # ====================================================
      # At 99.99%, 14x burn rate = 14 * 0.0001 = 0.0014 error rate

      - alert: SloBudgetBurnP0_Tier0
        expr: |
          (
            (1 - sum(rate(sli_good_total{service="cc-connect"}[1h])) by (service)
               / sum(rate(sli_valid_total{service="cc-connect"}[1h])) by (service))
            > 14 * 0.0001
          )
          and
          (
            (1 - sum(rate(sli_good_total{service="cc-connect"}[5m])) by (service)
               / sum(rate(sli_valid_total{service="cc-connect"}[5m])) by (service))
            > 14 * 0.0001
          )
        for: 1m
        labels:
          severity: critical
          tier: "0"
        annotations:
          summary: "P0: cc-connect burning budget at 14x rate"
          description: "cc-connect is experiencing significant downtime. Budget will exhaust in <2h."
          runbook: "docs/infra/runbooks/p0-budget-burn.md"

      - alert: SloBudgetBurnP1_Tier0
        expr: |
          (
            (1 - sum(rate(sli_good_total{service="cc-connect"}[6h])) by (service)
               / sum(rate(sli_valid_total{service="cc-connect"}[6h])) by (service))
            > 6 * 0.0001
          )
          and
          (
            (1 - sum(rate(sli_good_total{service="cc-connect"}[30m])) by (service)
               / sum(rate(sli_valid_total{service="cc-connect"}[30m])) by (service))
            > 6 * 0.0001
          )
        for: 3m
        labels:
          severity: warning
          tier: "0"
        annotations:
          summary: "P1: cc-connect burning budget at 6x rate"

      # ====================================================
      # Tier-2 Alert Rules (99.5% SLO)
      # ====================================================
      # 14x burn rate = 14 * 0.005 = 0.07 error rate

      - alert: SloBudgetBurnP0_Tier2
        expr: |
          (
            (1 - sum(rate(sli_good_total{service=~"vector|sing_box"}[1h])) by (service)
               / sum(rate(sli_valid_total{service=~"vector|sing_box"}[1h])) by (service))
            > 14 * 0.005
          )
          and
          (
            (1 - sum(rate(sli_good_total{service=~"vector|sing_box"}[5m])) by (service)
               / sum(rate(sli_valid_total{service=~"vector|sing_box"}[5m])) by (service))
            > 14 * 0.005
          )
        for: 5m
        labels:
          severity: critical
          tier: "2"
        annotations:
          summary: "P0: {{ $labels.service }} burning budget at 14x rate"

      - alert: SloBudgetBurnP1_Tier2
        expr: |
          (
            (1 - sum(rate(sli_good_total{service=~"vector|sing_box"}[6h])) by (service)
               / sum(rate(sli_valid_total{service=~"vector|sing_box"}[6h])) by (service))
            > 6 * 0.005
          )
          and
          (
            (1 - sum(rate(sli_good_total{service=~"vector|sing_box"}[30m])) by (service)
               / sum(rate(sli_valid_total{service=~"vector|sing_box"}[30m])) by (service))
            > 6 * 0.005
          )
        for: 5m
        labels:
          severity: warning
          tier: "2"
        annotations:
          summary: "P1: {{ $labels.service }} burning budget at 6x rate"

      # ====================================================
      # Tier-3 Alert Rules (99.0% SLO)
      # ====================================================
      # 14x burn rate = 14 * 0.01 = 0.14 error rate
      # P0 only (Tier-3 services get less aggressive alerting)

      - alert: SloBudgetBurnP0_Tier3
        expr: |
          (
            (1 - sum(rate(sli_good_total{service=~"grafana|build_runner"}[6h])) by (service)
               / sum(rate(sli_valid_total{service=~"grafana|build_runner"}[6h])) by (service))
            > 6 * 0.01
          )
          and
          (
            (1 - sum(rate(sli_good_total{service=~"grafana|build_runner"}[30m])) by (service)
               / sum(rate(sli_valid_total{service=~"grafana|build_runner"}[30m])) by (service))
            > 6 * 0.01
          )
        for: 10m
        labels:
          severity: warning
          tier: "3"
        annotations:
          summary: "Tier-3 service {{ $labels.service }} budget burning at >6x"

      # ====================================================
      # Budget Exhaustion Alert (all tiers)
      # ====================================================

      - alert: SloBudgetExhausted
        expr: |
          slo:budget_remaining:tier1:30d == 0
          or slo:budget_remaining:tier2:30d == 0
          or slo:budget_remaining:tier3:30d == 0
          or slo:budget_remaining:cc_connect:30d == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "ERROR BUDGET EXHAUSTED: {{ $labels.service }}"
          description: "{{ $labels.service }} has exhausted its error budget for the rolling 30d window. Emergency response required."
          runbook: "docs/infra/runbooks/budget-exhausted.md"
```

### 5.3 Tier-Specific Thresholds Summary

| Tier | SLO | Daily Budget | P0 (14x) Error Rate | P1 (6x) Error Rate | P2 (2x) Error Rate |
|------|-----|-------------|--------------------|--------------------|--------------------|
| 0 | 99.99% | ~8.6s | >0.14% | >0.06% | >0.02% |
| 1 | 99.9% | ~86s | >1.4% | >0.6% | >0.2% |
| 2 | 99.5% | ~7.2m | >7% | >3% | >1% |
| 3 | 99.0% | ~14.4m | >14% | >6% | >2% |

### 5.4 Reducing Alert Fatigue

To prevent false positives from transient issues:

1. **Short `for` duration**: 1-5 minutes. Long enough to filter scrape blips, short enough to catch real issues.
2. **Multi-window AND**: Both short window (5m/30m/6h) AND long window (1h/6h/3d) must exceed threshold. This prevents false positives from a single bad minute.
3. **No alert on zero traffic**: If a service has zero valid events in the window, skip evaluation (Prometheus returns no data, alert does not fire).
4. **Maintenance window suppression**: During planned maintenance, a `maintenance` annotation on the target suppresses SLO alerts:
   ```yaml
   # In scrape config, add during maintenance
   relabel_configs:
     - target_label: __maintenance
       replacement: "true"
   ```
5. **P3 daily digest**: Only fire P3 as a single daily notification, not per-evaluation.

---

## 6. Error Budget Tracking

### 6.1 Budget Remaining Computation

Error budget remaining is computed as:

```
budget_remaining = 1 - (error_rate / (1 - SLO_target))

Where:
  error_rate = 1 - (good_events / total_events) over the rolling 30d window
  (1 - SLO_target) = maximum allowed error rate
```

When `budget_remaining` hits 0, the budget is exhausted. When it's 1.0, the budget is full.

### 6.2 Prometheus Budget Metrics

The recording rules in Section 4.4 produce these budget metrics per service:

| Metric | Query | Description |
|--------|-------|-------------|
| `slo:budget_remaining:cc_connect:30d` | `slo:budget_remaining:cc_connect:30d` | cc-connect budget (99.99% SLO) |
| `slo:budget_remaining:tier1:30d` | `slo:budget_remaining:tier1:30d{service="postgresql"}` | Per Tier-1 service |
| `slo:budget_remaining:tier2:30d` | `slo:budget_remaining:tier2:30d{service="vector"}` | Per Tier-2 service |
| `slo:budget_remaining:tier3:30d` | `slo:budget_remaining:tier3:30d{service="grafana"}` | Per Tier-3 service |

### 6.3 Budget Remaining ClickHouse Recording

For long-term budget history (beyond Prometheus retention of 30d), write budget snapshots to ClickHouse:

```sql
CREATE TABLE infra.slo_budget_snapshots
(
    `timestamp`        DateTime CODEC(DoubleDelta, ZSTD),
    `service`          LowCardinality(String),
    `cluster`          LowCardinality(String),
    `tier`             UInt8,
    `slo_target`       Float32,
    `availability_30d` Float32,
    `budget_remaining` Float32,      -- 0.0 to 1.0
    `burn_rate_1h`     Float32,
    `burn_rate_6h`     Float32,
    `burn_rate_24h`    Float32,
    `_inserted_at`     DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service, timestamp);
```

Data is written every 5 minutes via a cron job in the boss container:

```bash
# ~/.kyb/bin/slo-snapshot
# Queries Prometheus and writes to ClickHouse
#
# Run via cron every 5 minutes

PROMETHEUS="http://localhost:9090"
CLICKHOUSE="http://localhost:8123"

for service in cc-connect postgresql clickhouse redis kafka vector sing-box grafana; do
  # Query Prometheus for budget remaining
  BUDGET=$(curl -s "${PROMETHEUS}/api/v1/query" \
    --data-urlencode "query=slo:budget_remaining:${service}:30d" \
    | jq -r '.data.result[0].value[1] // "null"')

  # Query availability
  AVAIL=$(curl -s "${PROMETHEUS}/api/v1/query" \
    --data-urlencode "query=slo:availability:30d{service=\"${service}\"}" \
    | jq -r '.data.result[0].value[1] // "null"')

  # Query burn rates
  BURN_1H=$(curl -s "${PROMETHEUS}/api/v1/query" \
    --data-urlencode "query=slo:burn_rate:1h{service=\"${service}\"}" \
    | jq -r '.data.result[0].value[1] // "null"')

  # Insert into ClickHouse
  curl -s -X POST "${CLICKHOUSE}" \
    -d "INSERT INTO infra.slo_budget_snapshots FORMAT JSONEachRow {
      \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"service\": \"${service}\",
      \"cluster\": \"mac-orbstack\",
      \"tier\": \"tier\",
      \"slo_target\": 0.999,
      \"availability_30d\": ${AVAIL:-null},
      \"budget_remaining\": ${BUDGET:-null},
      \"burn_rate_1h\": ${BURN_1H:-null}
    }"
done
```

### 6.4 Budget Exhaustion Policy

When budget drops below thresholds, actions are taken automatically via Alertmanager:

| Budget Remaining | Alert | Action |
|-----------------|-------|--------|
| < 50% | P2 ticket | Schedule investigation |
| < 30% | P1 page | Freeze non-critical changes to this service |
| < 10% | P0 page | Freeze ALL changes, emergency standup |
| 0% | P0 page | Emergency bridge, rollback recent changes |

**Deployment freeze mechanics:**

When `slo:budget_remaining:${service}:30d < 0.30` fires:

1. Alertmanager sends a webhook to cc-connect with the freeze signal.
2. cc-connect posts a freeze notice to `kyb-kindergarden` with the affected service.
3. The freeze must be acknowledged within 15 minutes (P1 response).
4. Freeze lifts automatically when `budget_remaining > 0.50` for 24 consecutive hours.

---

## 7. SLO Dashboard

### 7.1 Dashboard Name

**Grafana dashboard:** `Infra SLO Overview`
**UID:** `infra-slo-overview`
**Refresh:** 30s (matches 2x scrape interval)

### 7.2 Dashboard Panels

#### Panel 1: SLO Compliance Gauge (top row)

A gauge per service showing rolling-30d availability vs SLO target.

| Property | Value |
|----------|-------|
| **Type** | Gauge (stat) |
| **Query** | `slo:availability:30d{service="$service"}` |
| **Unit** | Percent (0-100) |
| **Thresholds** | Green >= SLO target, Yellow >= SLO-0.1%, Red < SLO-0.1% |
| **Repeat** | By `service` label, 4 per row |

Grafana query:
```promql
# cc-connect compliance
slo:availability:30d{service="cc-connect"} * 100

# Tier-1 compliance
slo:availability:30d{service=~"postgresql|clickhouse|redis|kafka"} * 100

# Tier-2/3 compliance
slo:availability:30d{service=~"vector|sing_box|grafana"} * 100
```

Threshold configuration per service:

| Service | Green (>=) | Yellow | Red (<) |
|---------|-----------|--------|---------|
| cc-connect | 99.99% | 99.98% | 99.98% |
| Tier-1 | 99.9% | 99.8% | 99.8% |
| Tier-2 | 99.5% | 99.4% | 99.4% |
| Tier-3 | 99.0% | 98.9% | 98.9% |

#### Panel 2: Error Budget Remaining (bar gauge)

One horizontal bar per service, color-coded by remaining budget.

| Property | Value |
|----------|-------|
| **Type** | Bar gauge (horizontal) |
| **Query** | `slo:budget_remaining:${service}:30d * 100` |
| **Unit** | Percent (0-100) |
| **Display** | One bar per service, sorted by remaining |
| **Color** | Green > 50%, Yellow 20-50%, Red 0-20%, Dark red 0 |

Grafana query (using unified metric):
```promql
# All services budget remaining
slo:budget_remaining:cc_connect:30d * 100
or slo:budget_remaining:tier1:30d * 100
or slo:budget_remaining:tier2:30d * 100
or slo:budget_remaining:tier3:30d * 100
```

#### Panel 3: Burn Rate Heatmap

| Property | Value |
|----------|-------|
| **Type** | Status history / State timeline |
| **Query** | Multiple queries, one per service |
| **Y-axis** | Service name |
| **X-axis** | Time (last 24h) |
| **Color** | Green < 1x, Yellow 1-6x, Orange 6-14x, Red >= 14x |

Each service row queries:
```promql
slo:burn_rate:1h{service="$service"}
```

Thresholds: 1x = yellow, 6x = orange, 14x = red.

#### Panel 4: Budget Consumption Timeline

| Property | Value |
|----------|-------|
| **Type** | Time series (stacked) |
| **Query** | Per-service budget remaining over time |
| **X-axis** | Time (last 30d) |
| **Y-axis** | Budget remaining % (100% to 0%) |

Grafana query:
```promql
# Tier-1 budget trend
slo:budget_remaining:tier1:30d{service="postgresql"}
```

#### Panel 5: Good vs Bad Events

| Property | Value |
|----------|-------|
| **Type** | Time series |
| **Queries** | Good events: `sum(rate(sli_good_total{service="$service"}[5m]))` |
| | Bad events: `sum(rate(sli_valid_total{service="$service"}[5m])) - sum(rate(sli_good_total{service="$service"}[5m]))` |
| **X-axis** | Time (last 1h) |
| **Y-axis** | Events per second |

#### Panel 6: Budget At Risk Summary

A stat panel showing count of services in each budget state:

| Property | Value |
|----------|-------|
| **Type** | Stat |
| **Queries** | |
| Healthy | `count(slo:budget_remaining:cc_connect:30d > 0.5) + count(slo:budget_remaining:tier1:30d > 0.5) + ...` |
| At Risk | `count(slo:budget_remaining:tier1:30d < 0.5 and slo:budget_remaining:tier1:30d > 0.2)` |
| Critical | `count(slo:budget_remaining:tier1:30d < 0.2)` |
| Exhausted | `count(slo:budget_remaining:tier1:30d == 0)` |

Alternatively, use a single PromQL for a "health score" stat:

```promql
# Overall SLO health score (average budget remaining across all services)
(
  avg(slo:budget_remaining:cc_connect:30d)
  + avg(slo:budget_remaining:tier1:30d)
  + avg(slo:budget_remaining:tier2:30d)
  + avg(slo:budget_remaining:tier3:30d)
) / 4
```

### 7.3 Per-Service Deep Dive Row

When a specific service is selected, a detailed row shows:

| Panel | Query | Description |
|-------|-------|-------------|
| 7d Trend | `slo:availability:7d{service="$service"}` | Weekly availability |
| 30d Trend | `slo:availability:30d{service="$service"}` | Monthly availability |
| Burn Rate 1h | `slo:burn_rate:1h{service="$service"}` | 1-hour burn rate gauge |
| Burn Rate 6h | `slo:burn_rate:6h{service="$service"}` | 6-hour burn rate gauge |
| Good Events | `rate(sli_good_total{service="$service"}[5m])` | Good event rate |
| Bad Events | `rate(sli_valid_total{service="$service"}[5m]) - rate(sli_good_total{service="$service"}[5m])` | Bad event rate |

### 7.4 Dashboard Variables

```yaml
variables:
  - name: cluster
    type: custom
    options:
      - mac-orbstack
      - aliyun
      - office
    default: mac-orbstack
    label: Cluster

  - name: tier
    type: custom
    options:
      - all
      - "0"
      - "1"
      - "2"
      - "3"
    default: all
    label: SLO Tier

  - name: service
    type: query
    query: label_values(slo:availability:30d, service)
    multi: true
    default: all
    label: Service

  - name: window
    type: interval
    values:
      - 1h
      - 6h
      - 24h
      - 7d
      - 30d
    default: 30d
    label: SLO Window
```

### 7.5 Dashboard JSON Annotations

Add annotation queries for incident markers:

```yaml
annotations:
  - name: Alerts
    datasource: Prometheus
    expr: ALERTS{alertname=~"SloBudgetBurn.*"}
    step: 60s
    title: "{{ alertname }}"
    text: "{{ description }}"
    tags: "{{ severity }}"
```

### 7.6 Dashboard Auto-Provisioning

The dashboard is provisioned via Grafana's provisioning system so it survives container restarts:

```yaml
# ~/.kyb/grafana/provisioning/dashboards/slo-tracking.yml
apiVersion: 1

providers:
  - name: "SLO Tracking"
    orgId: 1
    folder: "Infra SLO"
    type: file
    options:
      path: /etc/grafana/dashboards/slo
```

Dashboard JSON stored at `~/.kyb/grafana/dashboards/slo/infra-slo-overview.json`:

```bash
# Export from Grafana after creating the dashboard:
curl -s http://admin:admin@localhost:3000/api/dashboards/uid/infra-slo-overview \
  | jq '.dashboard' > ~/.kyb/grafana/dashboards/slo/infra-slo-overview.json
```

---

## 8. Multi-Cluster Aggregation

### 8.1 Per-Cluster SLO View

Each cluster has its own SLO view using the `cluster` label. The central Prometheus already labels all metrics with `cluster` via scrape config relabeling.

Cluster-level budget:
```promql
# Average budget remaining per cluster
avg(slo:budget_remaining:tier1:30d) by (cluster)
```

### 8.2 Cross-Cluster SLO Summary

A dedicated panel in the SLO dashboard shows a cross-cluster summary:

```
Cluster            Budget Remaining    Services at Risk    Status
mac-orbstack       87%                 PostgreSQL-14       Healthy
aliyun             92%                 -                   Healthy
office             78%                 feishu-bridge-sync  At risk
```

```promql
# Cluster budget remaining (average across all services in cluster)
avg(slo:budget_remaining:cc_connect:30d{cluster="mac-orbstack"})
or avg(slo:budget_remaining:tier1:30d{cluster="mac-orbstack"})
or avg(slo:budget_remaining:tier2:30d{cluster="mac-orbstack"})
or avg(slo:budget_remaining:tier3:30d{cluster="mac-orbstack"})
```

### 8.3 Multi-Cluster Burn Rate Alerts

For cross-cluster services (e.g., ACR mirror on Aliyun), burn rate alerts use the `cluster` label:

```yaml
- alert: SloBudgetBurnP1_RemoteCluster
  expr: |
    (
      (1 - sum(rate(sli_good_total{cluster="aliyun"}[6h])) by (service)
         / sum(rate(sli_valid_total{cluster="aliyun"}[6h])) by (service))
      > 6 * 0.005
    )
    and
    (
      (1 - sum(rate(sli_good_total{cluster="aliyun"}[30m])) by (service)
         / sum(rate(sli_valid_total{cluster="aliyun"}[30m])) by (service))
      > 6 * 0.005
    )
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "P1: {{ $labels.service }} on {{ $labels.cluster }} burning budget at 6x rate"
```

### 8.4 Super-Boss Global SLO View

The super-boss (current session) can query the aggregated SLO dashboard to see health across all clusters. A top-level panel shows:

```promql
# Global SLO health
avg(slo:budget_remaining:cc_connect:30d)                                     # cc-connect globally
avg(slo:budget_remaining:tier1:30d)                                           # Tier-1 globally
min(slo:budget_remaining:tier1:30d) by (cluster, service)                     # Worst service per cluster
count(slo:budget_remaining:tier1:30d < 0.3) by (cluster)                      # Services at risk per cluster
```

A single stat panel shows the **Global SLO Health Score**:

```promql
# Global health: 0-100, weighted by tier importance
(
  avg(slo:budget_remaining:cc_connect:30d) * 3     # Tier-0 weighted 3x
  + avg(slo:budget_remaining:tier1:30d) * 2         # Tier-1 weighted 2x
  + avg(slo:budget_remaining:tier2:30d) * 1          # Tier-2 weighted 1x
  + avg(slo:budget_remaining:tier3:30d) * 0.5        # Tier-3 weighted 0.5x
) / 6.5 * 100                                         # Normalize to 0-100
```

---

## 9. Alert Routing & Escalation

### 9.1 Alertmanager Configuration for SLO Alerts

```yaml
# ~/.kyb/prometheus/alertmanager/alertmanager.yml
route:
  receiver: "feishu-default"
  group_by: ["alertname", "service", "cluster"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # P0 SLO alerts: immediate, @all
    - match:
        alertname: "SloBudgetBurnP0_.*"
      receiver: "feishu-slo-p0"
      repeat_interval: 15m
      continue: true

    # P1 SLO alerts: on-call within 15min
    - match:
        alertname: "SloBudgetBurnP1_.*"
      receiver: "feishu-slo-p1"
      repeat_interval: 1h
      continue: true

    # P2 SLO alerts: business hours ticket
    - match:
        alertname: "SloBudgetBurnP2_.*"
      receiver: "feishu-slo-p2"
      repeat_interval: 4h
      continue: true

    # Budget exhausted: emergency
    - match:
        alertname: "SloBudgetExhausted"
      receiver: "feishu-slo-p0"
      repeat_interval: 5m

receivers:
  - name: "feishu-default"
    webhook_configs:
      - url: "http://kyb-infra-cc-connect:9091/webhook/alert"
        send_resolved: true

  - name: "feishu-slo-p0"
    webhook_configs:
      - url: "http://kyb-infra-cc-connect:9091/webhook/alert"
        send_resolved: true
        http_config:
          headers:
            X-Alert-Priority: "P0"
            X-Alert-SLO: "true"

  - name: "feishu-slo-p1"
    webhook_configs:
      - url: "http://kyb-infra-cc-connect:9091/webhook/alert"
        send_resolved: true
        http_config:
          headers:
            X-Alert-Priority: "P1"
            X-Alert-SLO: "true"

  - name: "feishu-slo-p2"
    webhook_configs:
      - url: "http://kyb-infra-cc-connect:9091/webhook/alert"
        send_resolved: true
        http_config:
          headers:
            X-Alert-Priority: "P2"
            X-Alert-SLO: "true"
```

### 9.2 cc-connect Webhook Format for SLO Alerts

cc-connect's `/webhook/alert` endpoint formats SLO alerts differently from infra alerts:

- **P0**: Red card in Feishu, @all mention, includes current budget remaining
- **P1**: Orange card, @oncall, includes burn rate
- **P2**: Yellow card, no @mention, mentions service owner

Alertmanager webhook payload for SLO alerts includes custom annotations:
```json
{
  "status": "firing",
  "alerts": [{
    "labels": {
      "alertname": "SloBudgetBurnP0_Tier1",
      "service": "kafka",
      "cluster": "mac-orbstack",
      "severity": "critical"
    },
    "annotations": {
      "summary": "P0: kafka burning budget at 14x rate",
      "description": "Service kafka consuming error budget at 14x rate. Budget will exhaust in ~3 days.",
      "budget_remaining": "0.65",
      "burn_rate": "14.2",
      "runbook": "docs/infra/runbooks/p0-budget-burn.md"
    }
  }]
}
```

### 9.3 Daily SLO Digest (P3)

A daily P3 report is generated by a cron job in the boss container:

```bash
# ~/.kyb/bin/slo-daily-digest
# Runs daily at 09:00 Asia/Shanghai
# Generates a summary of SLO status for all services

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROMETHEUS="http://localhost:9090"
CK="http://localhost:8123"

# Build the report
REPORT="=== SLO Daily Report ($(date +%Y-%m-%d)) ===\n\n"

for service in cc-connect postgresql clickhouse redis kafka vector sing-box grafana; do
  AVAIL=$(curl -s "${PROMETHEUS}/api/v1/query" \
    --data-urlencode "query=slo:availability:30d{service=\"${service}\"}" \
    | jq -r '.data.result[0].value[1] // "N/A"')
  BUDGET=$(curl -s "${PROMETHEUS}/api/v1/query" \
    --data-urlencode "query=slo:budget_remaining:${service}:30d" \
    | jq -r '.data.result[0].value[1] // "N/A"')

  # Color-code
  if [ "$(echo "${BUDGET} > 0.5" | bc -l 2>/dev/null)" = "1" ]; then
    STATUS="HEALTHY"
  elif [ "$(echo "${BUDGET} > 0.2" | bc -l 2>/dev/null)" = "1" ]; then
    STATUS="AT RISK"
  elif [ "$(echo "${BUDGET} > 0" | bc -l 2>/dev/null)" = "1" ]; then
    STATUS="CRITICAL"
  else
    STATUS="EXHAUSTED"
  fi

  REPORT+="  ${service}: ${AVAIL}% (budget: ${BUDGET}%) [${STATUS}]\n"
done

REPORT+="\nServices at risk: $(curl -s \"${PROMETHEUS}/api/v1/query\" \
  --data-urlencode 'query=count(slo:budget_remaining:tier1:30d < 0.3)' \
  | jq -r '.data.result[0].value[1] // "0"')\n"
REPORT+="Services exhausted: $(curl -s \"${PROMETHEUS}/api/v1/query\" \
  --data-urlencode 'query=count(slo:budget_remaining:tier1:30d == 0)' \
  | jq -r '.data.result[0].value[1] // "0"')\n"

# Send to Feishu via cc-connect
curl -s -X POST "http://kyb-infra-cc-connect:9091/send" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"kyb-kindergarden\",
    \"text\": \"$(echo -e "${REPORT}" | jq -Rs .)\"
  }"
```

---

## 10. Implementation Plan

### 10.1 Phase 1: SLO Recording Rules (Day 1)

**Objective:** Set up Prometheus recording rules for SLO good/valid events, availability, and budget remaining.

- [ ] Write `~/.kyb/prometheus/rules/slo-recording.yml` with per-service good/valid rules
- [ ] Write `~/.kyb/prometheus/rules/slo-alerts.yml` with MWMBR alert rules
- [ ] Deploy rules to Prometheus (`scp` or `docker cp`)
- [ ] Reload Prometheus config: `curl -X POST http://localhost:9090/-/reload`
- [ ] Verify recording rules appear in Prometheus: `/api/v1/rules`
- [ ] Test: `curl http://localhost:9090/api/v1/query?query=slo:availability:30d`

**Effort:** 1 hour. Owner: infra-boss.

### 10.2 Phase 2: Blackbox Probes (Day 1)

**Objective:** Deploy blackbox exporter and configure probes for services without native metrics.

- [ ] Deploy blackbox exporter:
  ```bash
  docker run -d \
    --name kyb-infra-blackbox-exporter \
    --restart unless-stopped \
    --network kyb-net \
    prom/blackbox-exporter:latest
  ```
- [ ] Write scrape config for HTTP/TCP probes (Section 3.3)
- [ ] Verify probe results: `probe_success{job="blackbox"}`
- [ ] Register probe targets in the SLO recording rules

**Effort:** 30 minutes. Owner: infra-boss.

### 10.3 Phase 3: SLO Dashboard (Day 1-2)

**Objective:** Build the Grafana SLO dashboard.

- [ ] Create dashboard: `Infra SLO Overview`
- [ ] Add Panel 1: Compliance gauge per service
- [ ] Add Panel 2: Budget remaining bar gauge
- [ ] Add Panel 3: Burn rate heatmap
- [ ] Add Panel 4: Budget consumption timeline
- [ ] Add Panel 5: Good vs Bad events
- [ ] Add Panel 6: Budget at risk summary
- [ ] Add per-service deep dive row
- [ ] Add annotations for alerts
- [ ] Set up dashboard variables (cluster, tier, service, window)
- [ ] Export dashboard JSON: `~/.kyb/grafana/dashboards/slo/infra-slo-overview.json`
- [ ] Configure dashboard provisioning

**Effort:** 2 hours. Owner: infra-boss.

### 10.4 Phase 4: Alert Routing (Day 2)

**Objective:** Configure Alertmanager for SLO-specific routing.

- [ ] Add SLO alert routes to Alertmanager config (Section 9.1)
- [ ] Implement cc-connect SLO webhook formatting (Section 9.2)
- [ ] Test each alert severity: force a probe failure and verify notification
- [ ] Set up P3 daily digest cron (Section 9.3)

**Effort:** 1 hour. Owner: infra-boss.

### 10.5 Phase 5: ClickHouse Budget Snapshots (Day 2)

**Objective:** Set up long-term budget history in ClickHouse.

- [ ] Create `infra.slo_budget_snapshots` table (Section 6.3)
- [ ] Write `~/.kyb/bin/slo-snapshot` script
- [ ] Add cron job (every 5 min):
  ```bash
  # crontab
  */5 * * * * /home/dev/.kyb/bin/slo-snapshot
  ```
- [ ] Verify data lands in ClickHouse: `SELECT * FROM infra.slo_budget_snapshots`

**Effort:** 30 minutes. Owner: infra-boss.

### 10.6 Phase 6: Multi-Cluster (Day 2-3)

**Objective:** Extend SLO tracking to Aliyun and Office clusters.

- [ ] Deploy blackbox exporter or metrics endpoint on remote clusters
- [ ] Add remote cluster scrape configs to central Prometheus (Tailscale targets)
- [ ] Verify remote targets are scraped: `up{cluster="aliyun"}`
- [ ] Add per-cluster SLO panels to dashboard (Section 8)
- [ ] Test cross-cluster alerts

**Effort:** 1 hour. Owner: infra-boss (via SSH dispatch).

### 10.7 Rollback Plan

SLO tracking is a monitoring-only layer. Rollback at any phase:

```bash
# Remove SLO recording rules
rm ~/.kyb/prometheus/rules/slo-recording.yml
rm ~/.kyb/prometheus/rules/slo-alerts.yml
curl -X POST http://localhost:9090/-/reload

# Remove SLO dashboard
curl -X DELETE http://admin:admin@localhost:3000/api/dashboards/uid/infra-slo-overview

# Remove ClickHouse table
echo "DROP TABLE infra.slo_budget_snapshots" | curl -X POST http://localhost:8123 --data-binary @-

# Stop snapshot cron
crontab -l | grep -v slo-snapshot | crontab -
```

No service depends on SLO tracking. Rollback is safe at any point.

---

## 11. Operational Runbook

### 11.1 Adding a New Service to SLO Tracking

```yaml
# Step-by-step:
# 1. Add probe (scrape config in ~/.kyb/prometheus/scrape_*.yml)
# 2. Add recording rules in slo-recording.yml:
#    - sli_good:<service>:total
#    - sli_valid:<service>:total
#    - slo:target:<service> (with SLO target value)
#    - slo:budget_remaining:<service>:30d
# 3. Add alert rules in slo-alerts.yml (or use generic tier rules)
# 4. Add service to Grafana dashboard panels (or it'll auto-appear if using unified queries)
# 5. Add service to slo-snapshot script
# 6. Add service to daily digest script
# 7. Register in error-budget.md service catalog
```

### 11.2 Investigating a Budget Burn Alert

When `SloBudgetBurnP0` fires:

```bash
# 1. Check current budget remaining
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=slo:budget_remaining:tier1:30d{service="kafka"}' \
  | jq '.data.result[0].value[1]'

# 2. Check current burn rate
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=slo:burn_rate:1h{service="kafka"}' \
  | jq '.data.result[0].value[1]'

# 3. Check raw availability
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=slo:availability:1d{service="kafka"}' \
  | jq '.data.result[0].value[1]'

# 4. Look at raw probe data
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=up{job="kafka"}' \
  | jq '.data.result'

# 5. Check logs
docker logs kyb-infra-kafka --tail 50
```

### 11.3 Monthly SLO Review

At the start of each month, generate a review report:

```bash
# ~/.kyb/bin/slo-monthly-review
# Generates a report for the previous month

MONTH=$(date -d "last month" +%Y-%m)
PROMETHEUS="http://localhost:9090"

echo "=== SLO Monthly Review ($MONTH) ==="
echo ""

# For each service, query the ClickHouse snapshots
clickhouse-client --query "
  SELECT
    service,
    avg(availability_30d) * 100 AS avg_availability,
    avg(budget_remaining) * 100 AS avg_budget,
    min(budget_remaining) * 100 AS min_budget,
    countIf(budget_remaining < 0.3) AS days_at_risk,
    countIf(budget_remaining = 0) AS days_exhausted
  FROM infra.slo_budget_snapshots
  WHERE toYYYYMM(timestamp) = '${MONTH}'
  GROUP BY service
  ORDER BY avg_budget ASC
" | column -t -s $'\t'
```

### 11.4 SLO Dashboard Emergency Access

If Grafana is down, get SLO data directly from Prometheus:

```bash
# Quick SLO status from CLI
for service in cc-connect postgresql clickhouse redis kafka vector sing-box grafana; do
  avail=$(curl -s "http://localhost:9090/api/v1/query" \
    --data-urlencode "query=slo:availability:30d{service=\"${service}\"}" \
    | jq -r '.data.result[0].value[1] // "N/A"')
  echo "${service}: ${avail}"
done
```

---

## Appendix A: SLO Metrics Manifest

Complete list of Prometheus metrics created by SLO tracking:

| Metric | Type | Labels | Purpose |
|--------|------|--------|---------|
| `sli_good_total` | Counter | `service`, `cluster` | Good events for dashboard |
| `sli_valid_total` | Counter | `service`, `cluster` | Total events for dashboard |
| `sli_good:<service>:total` | Counter | `service`, `cluster` | Good events per service (source of truth) |
| `sli_valid:<service>:total` | Counter | `service`, `cluster` | Total events per service |
| `slo:availability:30d` | Gauge | `service`, `cluster` | 30-day rolling availability |
| `slo:availability:7d` | Gauge | `service`, `cluster` | 7-day rolling availability |
| `slo:availability:1d` | Gauge | `service`, `cluster` | 1-day rolling availability |
| `slo:budget_remaining:<service>:30d` | Gauge | `service` | Budget remaining 0.0-1.0 |
| `slo:burn_rate:1h` | Gauge | `service` | 1-hour burn rate |
| `slo:burn_rate:5m` | Gauge | `service` | 5-minute burn rate |
| `slo:burn_rate:6h` | Gauge | `service` | 6-hour burn rate |

## Appendix B: Storage Estimates

| Component | Storage (30d) | Notes |
|-----------|--------------|-------|
| SLO recording rules | ~1 MB | ~50 time series, 60s interval |
| Blackbox probes | ~0.5 MB | ~10 targets, 30s scrape interval |
| ClickHouse snapshots | ~10 MB | ~10 services x 288 snapshots/day x 30d |
| **Total additional** | **~12 MB** | Negligible compared to existing metrics (~2-5 GB) |

## Appendix C: Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `slo:availability:30d` returns no data | Recording rule not evaluating | Check Prometheus `/api/v1/rules` for rule status |
| Budget remaining always 0 | Division by (1 - SLO) producing NaN | Check SLO target value (must be < 1.0) |
| Burn rate alerts not firing | Multi-window AND condition too strict | Verify both short and long window queries return data |
| Blackbox probe failing | Target unreachable or module mismatch | Check `probe_success` metric and blackbox exporter logs |
| SLO dashboard showing gaps | Prometheus scrape failure | Check `up` metric for the target job |
| Cross-cluster scrape failing | Tailscale routing issue | Verify Tailscale IP reachable from container |

---

> **Summary:** SLO tracking is implemented as Prometheus recording rules + Alertmanager burn rate alerts + Grafana dashboard. Each service has a defined SLI probe (uptime, request success, or throughput-based). Burn rate alerts use the MWMBR pattern with P0/P1/P2/P3 severity. Budget remaining is tracked as a Prometheus gauge metric and snapshotted to ClickHouse for long-term history. The SLO dashboard provides a unified view across all clusters and services.
>
> Estimated effort: 2-3 days for full rollout across all clusters.
>
> ／人◕ ‿‿ ◕人＼
