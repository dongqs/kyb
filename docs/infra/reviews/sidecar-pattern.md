---
decision: 稍后做
---

# Sidecar Pattern for Observability per Container

> **Status:** Design Document
> **Date:** 2026-05-23
> **Scope:** Standardized sidecar pattern for log, metric, and trace shipping from every infra container across all clusters.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Sidecar Model in Docker](#2-sidecar-model-in-docker)
3. [Component Stack](#3-component-stack)
4. [Per-Service Sidecar Configuration](#4-per-service-sidecar-configuration)
5. [Reference Implementation: Vector Sidecar](#5-reference-implementation-vector-sidecar)
6. [Orchestration & Lifecycle](#6-orchestration--lifecycle)
7. [Central Pipeline & Storage](#7-central-pipeline--storage)
8. [Grafana Data Sources](#8-grafana-data-sources)
9. [Comparison: Sidecar vs. Daemon vs. Docker Log Driver](#9-comparison-sidecar-vs-daemon-vs-docker-log-driver)

---

## 1. Problem Statement

### Current State

Every infra container (PG, Redis, Kafka, ClickHouse, sing-box, Grafana) writes logs to stdout/stderr. The only structured observability today is:

- **Heartbeats** -- each cluster boss POSTs JSON to central ClickHouse every 60s
- **cc-connect structured logs** -- shipped via Vector to ClickHouse
- **OTel traces** -- designed for cc-connect but not yet deployed for other services

There is no uniform mechanism for:
- Collecting **container logs** from all infra services
- Exposing **Prometheus metrics** from services that natively support them (e.g., PG exporter, Redis exporter, Kafka exporter)
- Forwarding **traces** from OTel-instrumented services to a central store
- **Correlating** logs, metrics, and traces across services (e.g., "what was the PG query latency when cc-connect reported a timeout?")

Each service today must be manually configured for log collection, metrics export, and trace forwarding. As the infra grows (more clusters, more services), this manual approach does not scale.

### Requirements

| Requirement | Detail |
|------------|--------|
| **Uniform** | Every infra container gets the same observability treatment |
| **Non-invasive** | No changes to the main service container image or entrypoint |
| **Container-native** | Works with Docker, no K8s dependency |
| **Low overhead** | < 5% CPU, < 128 MB RAM per sidecar |
| **Fault-tolerant** | Buffered shipping, no data loss on short central outages |
| **Self-observable** | Sidecar health + metrics shipped alongside service data |

---

## 2. Sidecar Model in Docker

In Kubernetes, a sidecar is a container in the same Pod, sharing network namespace and volumes. In Docker Compose, the same pattern uses `network_mode: "service:..."` or shared volumes.

For kyb's flat Docker deployment (no K8s), the sidecar pattern is:

### 2.1 Shared Network Namespace

```
┌────────────────────────────────────────┐
│         docker-compose service         │
│                                        │
│  ┌─────────────────┐  ┌──────────────┐│
│  │  Main Container  │  │   Sidecar    ││
│  │  (PG / Redis /   │  │  (Vector /   ││
│  │   Kafka / etc.)  │  │   Exporter)  ││
│  │                  │  │              ││
│  │  logs → stdout   │  │  reads logs  ││
│  │  metrics → :9187 │←─────:9187     ││
│  │  OTLP → :4318    │←─────:4318     ││
│  └─────────────────┘  └──────┬───────┘│
│                              │        │
│                    ships to central CK │
└────────────────────────────────────────┘
```

**Mechanism:**

```yaml
services:
  postgres-16:
    image: postgres:16
    networks: [kyb-net]

  vector-sidecar-pg16:
    image: timberio/vector:0.42-alpine
    network_mode: "service:postgres-16"
    volumes:
      - ./vector/pg16.toml:/etc/vector/vector.toml:ro
      - /var/lib/docker/containers:/host/containers:ro  # optional: direct log access
    depends_on: [postgres-16]
```

### 2.2 Shared Mount for Log Files

When `docker logs` is insufficient (e.g., want structured file-based log tailing), mount the Docker host's container log directory:

```yaml
volumes:
  - /var/lib/docker/containers:/var/log/containers:ro
```

The sidecar uses `docker logs` plugin or reads the JSON log files directly. For most kyb services, `docker logs --tail` via the Docker API is simpler.

### 2.3 Sidecar Types per Service

Not every service needs all three observability pillars:

| Pillar | Mechanism | Sidecar Component |
|--------|-----------|-------------------|
| **Logs** | Container stdout/stderr → Vector | Vector |
| **Metrics** | Prometheus exporter endpoint → scrape | Prometheus Node Exporter + per-service exporter |
| **Traces** | OTLP export | OTel Collector (standalone, one per host not per container) |

**Decision:** Combine log + metric shipping into a single Vector sidecar per service. Traces use a shared OTel Collector per host (because trace volume is low and the collector is stateless).

---

## 3. Component Stack

### 3.1 Vector (Primary Sidecar)

**Role:** Collect logs, transform to structured JSON, ship to central ClickHouse.

**Why Vector over alternatives:**

| Feature | Vector | Fluentd | Logstash | Filebeat |
|---------|--------|---------|----------|----------|
| Language | Rust | Ruby | JRuby | Go |
| Memory | ~10-30 MB | ~100-200 MB | ~300-600 MB | ~20-40 MB |
| ClickHouse sink | Native | Plugin | Plugin | No |
| VRL transform | Built-in | Limited | Ruby DSL | Limited |
| OTel support | Native | Plugin | Plugin | No |
| Prometheus metrics | Built-in | Plugin | Plugin | Limited |

Vector is the clear winner for ClickHouse-targeted log shipping: native ClickHouse sink, low memory footprint, and VRL for transformations.

### 3.2 Prometheus Exporters (Per-Service)

For metrics, each service that exposes a Prometheus endpoint gets a scrape target:

| Service | Exporter | Port | Endpoint |
|---------|----------|------|----------|
| PostgreSQL | `prometheuscommunity/postgres-exporter` | 9187 | `/metrics` |
| Redis | `redis/redis-stack-server` (built-in) or `oliver006/redis_exporter` | 9121 | `/metrics` |
| Kafka | `danielqsj/kafka-exporter` | 9308 | `/metrics` |
| ClickHouse | ClickHouse built-in (port 8123, endpoint `/metrics`) | 8123 | `/metrics` |
| Node (host) | `prom/node-exporter` | 9100 | `/metrics` |

Each exporter runs as a sidecar or alongside the service, keeping the main container image clean.

### 3.3 OTel Collector (Per-Host)

**Not per-container.** Trace volume is low (~500 spans/day currently), so a single OTel Collector per host is sufficient:

```yaml
otel-collector:
  image: otel/opentelemetry-collector-contrib:0.117.0
  ports:
    - "4317:4317"   # gRPC OTLP
    - "4318:4318"   # HTTP OTLP
  volumes:
    - ./otel/config.yaml:/etc/otel/config.yaml:ro
  command: ["--config=/etc/otel/config.yaml"]
```

The OTel Collector receives OTLP from any OTel-instrumented service (cc-connect, future Go services) and forwards to Grafana Tempo (traces) and Prometheus (metrics derived from spans).

### 3.4 Prometheus + Grafana Mimir (Per-Host or Central)

- **Local Prometheus** per host for low-latency alerting
- **Remote write** to central Grafana Mimir (or VictoriaMetrics) for global queries
- Or: ship directly to central CK via Vector's Prometheus remote write receiver

For kyb's current scale (3 clusters, ~15 services), a single central Prometheus/Mimir on Mac/Orbstack is sufficient, with remote write from each cluster's Prometheus.

---

## 4. Per-Service Sidecar Configuration

### 4.1 PostgreSQL 16

**Logs:** PG logs to stdout. Vector parses PG log format and enriches with service labels.

```toml
# vector/pg16.toml
[sources.pg_logs]
type = "docker_logs"
containers = ["kyb-infra-pg16"]

[transforms.parse_pg]
type = "remap"
inputs = ["pg_logs"]
source = '''
  .service = "postgresql-16"
  .cluster = "${CLUSTER_NAME}"
  .log_type = "postgresql"
  parsed = parse_regex!(.message, r'^(?P<severity>\w+):\s+(?P<detail>.*)')
  .severity = parsed.severity
  .detail = parsed.detail
'''

[sinks.pg_to_ck]
type = "clickhouse"
inputs = ["parse_pg"]
endpoint = "${CK_ENDPOINT}"
table = "infra_logs"
auth.strategy = "none"
encoding.id = "json"
```

**Metrics:** Sidecar `prometheuscommunity/postgres-exporter`:

```bash
docker run -d \
  --name pg-exporter-16 \
  --network kyb-net \
  -e DATA_SOURCE_NAME="postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable" \
  prometheuscommunity/postgres-exporter:latest
```

**Data source name** uses `postgres:postgres` (trust auth inside the Docker network; no SSL needed).

### 4.2 Redis

**Logs:** Redis logs to stdout. Vector parses and ships.

```toml
# vector/redis.toml
[sources.redis_logs]
type = "docker_logs"
containers = ["kyb-infra-redis"]

[transforms.parse_redis]
type = "remap"
inputs = ["redis_logs"]
source = '''
  .service = "redis"
  .cluster = "${CLUSTER_NAME}"
  .log_type = "redis"
  # Redis log format: "1234:M 23 May 10:00:00.123 * <message>"
  # Strip timestamp, keep severity (*, -, #)
'''

[sinks.redis_to_ck]
type = "clickhouse"
inputs = ["parse_redis"]
endpoint = "${CK_ENDPOINT}"
table = "infra_logs"
encoding.id = "json"
```

**Metrics:** Sidecar `oliver006/redis_exporter`:

```bash
docker run -d \
  --name redis-exporter \
  --network kyb-net \
  -e REDIS_ADDR=redis://localhost:6379 \
  oliver006/redis_exporter:latest
```

### 4.3 Kafka

**Logs:** Kafka is verbose. Filter to WARN+ by default, full logs on DEBUG setting.

```toml
# vector/kafka.toml
[sources.kafka_logs]
type = "docker_logs"
containers = ["kyb-infra-kafka"]

[transforms.filter_kafka]
type = "filter"
inputs = ["kafka_logs"]
condition = '.message | includes("ERROR") or .message | includes("WARN") or .message | includes("FATAL")'

[transforms.parse_kafka]
type = "remap"
inputs = ["filter_kafka"]
source = '''
  .service = "kafka"
  .cluster = "${CLUSTER_NAME}"
  .log_type = "kafka"
'''
```

**Metrics:** Sidecar `danielqsj/kafka-exporter`:

```bash
docker run -d \
  --name kafka-exporter \
  --network kyb-net \
  danielqsj/kafka-exporter:latest \
  --kafka.server=localhost:9092
```

### 4.4 ClickHouse

**Logs:** ClickHouse is the log destination, but also logs itself. Ship its own logs back to itself (cycle).

```toml
# vector/clickhouse.toml
[sources.ck_logs]
type = "docker_logs"
containers = ["kyb-infra-clickhouse"]

[transforms.parse_ck]
type = "remap"
inputs = ["ck_logs"]
source = '''
  .service = "clickhouse"
  .cluster = "${CLUSTER_NAME}"
  .log_type = "clickhouse"
  .severity = upcase(string!(.severity))
'''

[sinks.ck_to_ck]
type = "clickhouse"
inputs = ["parse_ck"]
endpoint = "${CK_ENDPOINT}"
table = "infra_logs"
encoding.id = "json"
```

**Metrics:** ClickHouse exposes Prometheus metrics natively at `http://localhost:8123/metrics`. Vector can scrape this directly using its `prometheus_scrape` source, avoiding a separate exporter sidecar.

### 4.5 sing-box (Proxy)

**Logs:** sing-box logs to stdout in JSON format. Minimal transformation needed.

```toml
# vector/singbox.toml
[sources.singbox_logs]
type = "docker_logs"
containers = ["kyb-infra-sing-box"]

[transforms.parse_singbox]
type = "remap"
inputs = ["singbox_logs"]
source = '''
  .service = "sing-box"
  .cluster = "${CLUSTER_NAME}"
  .log_type = "singbox"
  # Already JSON, just add metadata
  if is_string(.message) {
    parsed = parse_json(.message) ?? {}
    .level = parsed.level
    .msg = parsed.msg
    .network = parsed.network
  }
'''
```

**Metrics:** No native Prometheus. Use Vector's internal metrics for connection counts and throughput, exported as Prometheus metrics from Vector itself.

### 4.6 Grafana

**Logs:** Grafana logs to stdout.

```toml
# vector/grafana.toml
[sources.grafana_logs]
type = "docker_logs"
containers = ["kyb-infra-grafana"]

[transforms.parse_grafana]
type = "remap"
inputs = ["grafana_logs"]
source = '''
  .service = "grafana"
  .cluster = "${CLUSTER_NAME}"
  .log_type = "grafana"
'''
```

**Metrics:** Grafana exposes `/metrics` natively on port 3000. Vector scrapes this directly.

### 4.7 kyb-infra-boss (Cluster Controller)

**Logs:** infra-boss runs as a kyb container. Its logs capture CLI output, agent interactions, heartbeat status.

```toml
# vector/boss.toml
[sources.boss_logs]
type = "docker_logs"
containers = ["kyb-infra-boss"]

[transforms.parse_boss]
type = "remap"
inputs = ["boss_logs"]
source = '''
  .service = "infra-boss"
  .cluster = "${CLUSTER_NAME}"
  .log_type = "boss"
  .boss_id = "${BOSS_ID}"
'''

[sinks.boss_to_ck]
type = "clickhouse"
inputs = ["parse_boss"]
endpoint = "${CK_ENDPOINT}"
table = "boss_logs"
encoding.id = "json"
```

---

## 5. Reference Implementation: Vector Sidecar

### 5.1 Base Vector Config (shared by all sidecars)

```toml
# vector/base.toml -- included by per-service configs

# Global
data_dir = "/var/lib/vector"

# Self-monitoring
[sources.internal_metrics]
type = "internal_metrics"
scrape_interval_secs = 15

[transforms.add_host]
type = "remap"
inputs = ["internal_metrics"]
source = '''
  .host = "${HOSTNAME}"
  .cluster = "${CLUSTER_NAME}"
'''

# Health check endpoint
[api]
enabled = true
address = "0.0.0.0:8686"

# Prometheus scrape endpoint for Vector's own metrics
[sinks.prometheus]
type = "prometheus_exporter"
inputs = ["internal_metrics"]
address = "0.0.0.0:9098"
```

### 5.2 Docker Compose Fragment

```yaml
x-sidecar-base: &sidecar-base
  image: timberio/vector:0.42-alpine
  restart: unless-stopped
  environment:
    CLUSTER_NAME: "${CLUSTER_NAME}"
    CK_ENDPOINT: "${CK_ENDPOINT:-http://host.docker.internal:8123}"
  volumes:
    - /var/lib/docker/containers:/var/log/containers:ro
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "3"

services:
  # --- PostgreSQL 16 ---
  postgres-16:
    image: postgres:16
    networks: [kyb-net]
    # ... main service config ...

  vector-postgres-16:
    <<: *sidecar-base
    network_mode: "service:postgres-16"
    volumes:
      - ./vector/pg16.toml:/etc/vector/vector.toml:ro
    depends_on: [postgres-16]

  postgres-exporter-16:
    image: prometheuscommunity/postgres-exporter:latest
    network_mode: "service:postgres-16"
    environment:
      DATA_SOURCE_NAME: "postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable"
    depends_on: [postgres-16]

  # --- ClickHouse ---
  clickhouse:
    image: clickhouse/clickhouse-server:24.3
    networks: [kyb-net]
    # ... main service config ...

  vector-clickhouse:
    <<: *sidecar-base
    network_mode: "service:clickhouse"
    volumes:
      - ./vector/clickhouse.toml:/etc/vector/vector.toml:ro
    depends_on: [clickhouse]
```

### 5.3 Standalone `docker run` (for existing services)

For services already running (created via `kyb create` or ad-hoc `docker run`), attach the sidecar after the fact:

```bash
# Given: kyb-infra-pg16 is already running
# Attach Vector sidecar sharing its network namespace

docker run -d \
  --name vector-pg16 \
  --network container:kyb-infra-pg16 \
  --pid container:kyb-infra-pg16 \
  -v /home/dev/projects/kyb/infra/vector/pg16.toml:/etc/vector/vector.toml:ro \
  -e CLUSTER_NAME=mac-orbstack \
  -e CK_ENDPOINT=http://host.docker.internal:8123 \
  timberio/vector:0.42-alpine

# Attach PG exporter sidecar
docker run -d \
  --name pg-exporter-16 \
  --network container:kyb-infra-pg16 \
  -e DATA_SOURCE_NAME="postgresql://postgres:postgres@localhost:5432/postgres?sslmode=disable" \
  prometheuscommunity/postgres-exporter:latest
```

The `--network container:<target>` flag is the key: it places the sidecar in the same network namespace as the target container, so `localhost` from the sidecar reaches the target container's ports.

---

## 6. Orchestration & Lifecycle

### 6.1 Bootstrap Script

```bash
# infra/observability/bootstrap.sh
# Run on each cluster to deploy all sidecars for existing infra containers.

CLUSTER_NAME="${1:?Usage: $0 <cluster-name>}"
CK_ENDPOINT="${2:-http://host.docker.internal:8123}"

deploy_sidecar() {
  local service_name=$1
  local target_container=$2
  local vector_config=$3
  local extra_containers=$4  # optional: space-separated exporter image refs

  echo "==> Deploying sidecar for $service_name ($target_container)"

  # Vector sidecar
  docker run -d \
    --name "vector-${service_name}" \
    --network "container:${target_container}" \
    -v "$(pwd)/infra/vector/${vector_config}":/etc/vector/vector.toml:ro \
    -e CLUSTER_NAME="${CLUSTER_NAME}" \
    -e CK_ENDPOINT="${CK_ENDPOINT}" \
    timberio/vector:0.42-alpine

  # Exporter sidecars (if any)
  for exporter in $extra_containers; do
    eval "$exporter"
  done

  echo "  OK"
}

# Deploy per service
deploy_sidecar "pg16" "kyb-infra-pg16" "pg16.toml" \
  'docker run -d --name pg-exporter-16 --network container:kyb-infra-pg16 ...'

deploy_sidecar "redis" "kyb-infra-redis" "redis.toml" \
  'docker run -d --name redis-exporter --network container:kyb-infra-redis ...'

# ... etc for each infra service
```

### 6.2 Health Check

```bash
# Check all sidecars are running
for sidecar in $(docker ps --format '{{.Names}}' | grep '^vector-\|^.*-exporter'); do
  if docker ps --filter "name=$sidecar" --format '{{.Status}}' | grep -q 'Up'; then
    echo "OK  : $sidecar"
  else
    echo "FAIL: $sidecar"
  fi
done

# Check Vector health API
curl -s http://localhost:8686/health
```

### 6.3 Restart Policy

All sidecar containers use `--restart unless-stopped`. If the main container restarts, the sidecar (which depends on the main container's network namespace) must also restart. Two approaches:

1. **Docker Compose** -- `depends_on` ensures restart ordering
2. **Ad-hoc `docker run`** -- use a watch script that detects the main container restart and re-creates the sidecar:

```bash
# infra/observability/sidecar-watch.sh
# Run as a systemd timer or in the infra-boss's cron loop
TARGETS="kyb-infra-pg16:vector-pg16 kyb-infra-redis:vector-redis ..."

for pair in $TARGETS; do
  MAIN="${pair%%:*}"
  SIDECAR="${pair##*:}"
  if ! docker ps --filter "name=$SIDECAR" --format '{{.Status}}' | grep -q 'Up'; then
    echo "Sidecar $SIDECAR not running for $MAIN, re-creating..."
    # Re-create logic here (or just alert)
  fi
done
```

### 6.4 Upgrade Strategy

Vector releases frequently. Upgrade sidecars without downtime:

```bash
# Pull new image
docker pull timberio/vector:0.43-alpine

# Recreate each sidecar (brief data loss window; Vector's disk buffer mitigates)
for sidecar in $(docker ps --format '{{.Names}}' | grep '^vector-'); do
  docker rm -f "$sidecar"
  # Re-create with new image tag
  # (bootstrap logic, or keep tag stable and use digest pinning)
done
```

For zero data loss: Vector's disk buffer (`data_dir`) persists across container restarts if mounted as a volume:

```yaml
volumes:
  - vector-data:/var/lib/vector
```

---

## 7. Central Pipeline & Storage

### 7.1 Data Flow Diagram

```
┌─────────────────────────────────────────────────────────┐
│                     Mac/Orbstack                         │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │  PG 16   │  │  Redis   │  │  Kafka   │  ...          │
│  │  +vector │  │  +vector │  │  +vector │              │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘              │
│       │             │             │                     │
│       └──────┬──────┴──────┬──────┘                     │
│              │             │                            │
│              ▼             ▼                            │
│       ┌──────────┐  ┌──────────┐                       │
│       │ ClickHouse│  │ Prometheus│                      │
│       │ (central) │  │ (central)│                      │
│       └──────────┘  └──────────┘                       │
│              │             │                            │
│              ▼             ▼                            │
│       ┌─────────────────────────┐                      │
│       │        Grafana          │                      │
│       │  (logs + metrics +     │                      │
│       │   traces via Tempo)    │                      │
│       └─────────────────────────┘                      │
│                                                         │
└─────────────────────────────────────────────────────────┘
         ▲                      ▲
         │ remote write         │ remote write
         │                      │
┌────────┴────────┐    ┌────────┴────────┐
│   Aliyun (sim)  │    │  Office (nuc8)  │
│                 │    │                 │
│ PG 16 +vector   │    │ PG 16 +vector   │
│ Redis +vector   │    │ Redis +vector   │
│ ...             │    │ ...             │
└─────────────────┘    └─────────────────┘
```

### 7.2 ClickHouse Schema

```sql
-- Central infra_logs table, receives from all clusters
CREATE TABLE infra_logs (
  timestamp DateTime64(3, 'Asia/Shanghai') DEFAULT now64(),
  cluster String,
  service String,
  container_name String,
  log_type String,          -- postgresql, redis, kafka, clickhouse, singbox, grafana, boss
  severity LowCardinality(String),
  message String,
  
  -- JSON metadata from VRL transformations
  extra String DEFAULT '{}' -- arbitrary JSON for service-specific fields

  -- Indexes
  INDEX idx_cluster_service (cluster, service) TYPE minmax GRANULARITY 1
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, cluster, service)
TTL timestamp + INTERVAL 90 DAY;

-- Boss-specific logs (separate table for higher write volume from agent activity)
CREATE TABLE boss_logs (
  timestamp DateTime64(3, 'Asia/Shanghai') DEFAULT now64(),
  boss_id String,
  cluster String,
  service String DEFAULT 'infra-boss',
  severity LowCardinality(String),
  message String,
  extra String DEFAULT '{}'
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, boss_id);

-- Prometheus metrics (remote write from each cluster's Prometheus)
-- Stored in Mimir / VictoriaMetrics / Prometheus itself
-- Not in ClickHouse unless using ClickHouse's Prometheus remote write integration
```

### 7.3 Storage Estimates

| Item | Daily Volume | 90-Day Total |
|------|-------------|--------------|
| Infra logs (all services, 3 clusters) | ~50 MB | ~4.5 GB |
| Boss logs (3 bosses) | ~10 MB | ~900 MB |
| Prometheus metrics | ~100 MB | ~9 GB |
| Traces (Tempo) | ~1 MB | ~90 MB |
| **Total** | **~161 MB** | **~14.5 GB** |

All fits comfortably on Mac/Orbstack's ~260 GB SSD.

---

## 8. Grafana Data Sources

### 8.1 Data Source Configuration

| Data Source | Type | URL | Use |
|------------|------|-----|-----|
| ClickHouse | ClickHouse datasource (plugin) | `http://host.docker.internal:8123` | Logs, structured events |
| Prometheus | Prometheus datasource | `http://prometheus:9090` or `host.docker.internal:9090` | Metrics, alerting |
| Tempo | Tempo datasource | `http://tempo:3200` | Distributed traces |

### 8.2 Dashboard Catalog

| Dashboard | Data Sources | Covers |
|-----------|-------------|--------|
| **Infra Overview** | Prometheus + CK | All services, cluster health, resource usage |
| **PostgreSQL Fleet** | Prometheus (PG exporter) + CK logs | Queries, connections, replication, errors |
| **Redis** | Prometheus (Redis exporter) + CK logs | Memory, ops/s, hit rate, slow logs |
| **Kafka** | Prometheus (Kafka exporter) + CK logs | Lag, throughput, partition health |
| **ClickHouse** | Prometheus (CK native) + CK logs (self) | Queries, merges, disk, replication |
| **Boss Activity** | CK (boss_logs) | Agent commands, heartbeat status, errors |
| **Network** | Prometheus (Node exporter) | Connection tracking, bandwidth, DNS |
| **Trace Explorer** | Tempo | Distributed trace search and waterfall |

### 8.3 Log Panel Example (ClickHouse query in Grafana)

```sql
SELECT
  $__timeInterval(timestamp) as time,
  cluster,
  service,
  count() as log_count,
  countIf(severity = 'ERROR' OR severity = 'FATAL') as error_count
FROM infra_logs
WHERE $__timeFilter(timestamp)
  AND cluster IN ($cluster)
  AND service IN ($service)
GROUP BY time, cluster, service
ORDER BY time
```

This query powers a "Log Volume by Service" panel, with template variables for cluster and service filtering.

---

## 9. Comparison: Sidecar vs. Daemon vs. Docker Log Driver

### 9.1 Options

| Aspect | Sidecar (Vector per container) | Daemon (one Vector per host) | Docker Log Driver (fluentd/syslog) |
|--------|-------------------------------|------------------------------|-----------------------------------|
| **Deployment** | One container per service | One container per host | Set in daemon.json, global |
| **Isolation** | Full (sidecar fails → only that service loses logs) | Shared (daemon fails → all services lose logs) | Global (driver fails → all containers) |
| **Resource usage** | ~15 MB per sidecar × 15 services = ~225 MB | ~30 MB total | ~5 MB (in Docker engine) |
| **Configuration** | Per-service granularity | Single config, must handle all formats | Limited to driver capabilities |
| **Transform capability** | Full VRL per service | Full VRL, but must multiplex | None (raw log forwarding) |
| **Network namespace** | Shares target's network (localhost access) | Host network (needs IP-based access) | N/A (Docker handles) |
| **Upgrade risk** | One sidecar at a time | Single point of failure during upgrade | Docker daemon restart needed |
| **Complexity** | Higher (more containers to manage) | Medium | Low |
| **Scalability** | Linear (more services = more sidecars) | Constant (one daemon) | Constant (driver in daemon) |

### 9.2 Recommendation

| Scenario | Pattern | Rationale |
|----------|---------|-----------|
| **New deployments** (Compose) | Sidecar | Clean isolation, per-service config, targets `localhost` |
| **Existing containers** (ad-hoc `docker run`) | Daemon | Simpler to attach to running services without recreating them |
| **High-volume log shipping** | Sidecar | Avoid daemon becoming bottleneck; disk buffer per service |
| **Low-resource hosts** (e.g., sim with 2 GB RAM) | Daemon | Sidecar overhead is measurable at 2 GB scale |
| **Quick setup / prototyping** | Docker log driver → Vector aggregator | Fastest path: set `log-driver` and have a central Vector ingest |

**For kyb infra: hybrid approach**

1. **Mac/Orbstack** (12+ services, 32 GB RAM) -- **Sidecar per service**. Full isolation, per-service tuning.
2. **Aliyun (sim)** (4-5 services, 2 GB RAM) -- **Daemon** (single Vector for all services). Resource-constrained, minimize overhead.
3. **Office (nuc8)** (4-5 services, 8 GB RAM) -- **Sidecar or Daemon** based on testing. Likely daemon for simplicity.

This hybrid gives us flexibility: the same config files work for both, just the deployment mechanism differs.

### 9.3 Future: Docker Compose as Standard

Once all infra services are codified in Docker Compose files (replacing ad-hoc `docker run` commands), the sidecar pattern becomes the default -- each service block in `compose.yaml` includes its vector and exporter sidecars. This is the target state.

---

## Appendix A: Sidecar Container Images

| Image | Size | Purpose |
|-------|------|---------|
| `timberio/vector:0.42-alpine` | ~25 MB | Log shipping, metrics scraping, VRL transforms |
| `prometheuscommunity/postgres-exporter:latest` | ~20 MB | PG metrics |
| `oliver006/redis_exporter:latest` | ~15 MB | Redis metrics |
| `danielqsj/kafka-exporter:latest` | ~50 MB | Kafka metrics |
| `prom/node-exporter:latest` | ~20 MB | Host metrics (one per host, not per service) |
| `otel/opentelemetry-collector-contrib:0.117.0` | ~150 MB | Trace collection (one per host, not per service) |

## Appendix B: Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | (required) | `mac-orbstack`, `aliyun`, `office` |
| `CK_ENDPOINT` | `http://host.docker.internal:8123` | ClickHouse HTTP endpoint |
| `CK_DATABASE` | `default` | ClickHouse database |
| `BOSS_ID` | `$(hostname)` | Unique boss identifier (for boss_logs) |
| `LOG_LEVEL` | `info` | Vector verbosity |
| `VECTOR_BUFFER_SIZE` | `104857600` | 100 MB disk buffer per sidecar |

## Appendix C: Related Documents

- Multi-cluster architecture: `docs/infra/multi-cluster-boss-architecture.md`
- OTel observability for cc-connect: `docs/infra/reviews/otel-cc-connect.md`
- OTel observability for patrol: `docs/infra/reviews/otel-patrol.md`
- Bridge observability design: `docs/infra/observability-design.md`
- Bridge metrics logging design: `docs/infra/designs/bridge-metrics-logging.md`

---

> ／人◕ ‿‿ ◕人＼
