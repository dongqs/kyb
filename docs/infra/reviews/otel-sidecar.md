---
decision: 稍微有点不确定等专家再审一轮
---

# OTel Sidecar Pattern -- Per-Container OTel Collector

> **Status:** Design Document
> **Date:** 2026-05-23
> **Scope:** Every infra container gets its own OTel Collector sidecar. Local OTLP endpoint per container, batch export to central backends.
> **Relationship to `sidecar-pattern.md`:** This doc defines the OTel-specific sidecar pattern (complementing the Vector-based log/metric sidecars defined in `sidecar-pattern.md`). It replaces the "per-host OTel Collector" assumption from that doc with a per-container approach justified below.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Why Per-Container OTel Collector?](#2-why-per-container-otel-collector)
3. [Architecture](#3-architecture)
4. [OTel Collector Configuration](#4-otel-collector-configuration)
5. [Deployment Patterns](#5-deployment-patterns)
6. [Service Integration Matrix](#6-service-integration-matrix)
7. [Export Pipeline](#7-export-pipeline)
8. [Operational Concerns](#8-operational-concerns)
9. [Comparison: Per-Container vs Per-Host OTel Collector](#9-comparison-per-container-vs-per-host-otel-collector)
10. [Implementation Roadmap](#10-implementation-roadmap)

---

## 1. Problem Statement

### Current State

The existing sidecar design (`sidecar-pattern.md`) uses:

- **Vector** as a per-container sidecar for logs and metrics
- **OTel Collector** as a single per-host daemon receiving OTLP from all containers on that host

This works but has architectural limitations:

1. **Single point of failure** -- One OTel Collector crash drops traces for all services on that host.
2. **Noisy-neighbor problem** -- A high-volume service (e.g., cc-connect with 90+ traces/day) can starve the collector's batch processor, delaying exports from quieter services.
3. **Coupling** -- Adding a new OTel-instrumented service requires updating the shared collector's config and restarting it (affecting all services).
4. **No per-service sampling** -- All services share one sampling decision. You cannot have 100% sampling for patrol traces and 10% for cc-connect from the same collector.
5. **Limited isolation** -- A memory leak or OOM in the collector's pipeline processing affects all tenants.

### Requirements

| Requirement | Detail |
|------------|--------|
| **Per-service isolation** | Each container's traces processed independently |
| **Local OTLP endpoint** | Each sidecar listens on localhost:4317/4318 within the target's network namespace |
| **Batch export** | Each sidecar batches independently with per-service tuning |
| **No shared state** | Sidecars do not share buffers, queues, or config |
| **Low overhead** | < 10% CPU, < 64 MB RAM per sidecar at current trace volume |
| **Graceful degradation** | Sidecar failure does not affect the main service container |
| **Self-observable** | Each sidecar exports its own metrics alongside service traces |

---

## 2. Why Per-Container OTel Collector?

### Trace Volume Context

Current trace volume estimation across all services:

| Service | Traces/Day | Spans/Trace | Spans/Day | Span Size | Daily Volume |
|---------|-----------|-------------|-----------|-----------|-------------|
| cc-connect | ~90 | ~6 | ~540 | ~200 B | ~108 KB |
| Patrol | ~288 (every 5 min) | ~8 | ~2,304 | ~300 B | ~691 KB |
| MCP servers | ~500 | ~7 | ~3,500 | ~250 B | ~875 KB |
| Infra services (PG, Redis, Kafka, CK) | ~50 | ~3 | ~150 | ~150 B | ~22 KB |
| **Total** | **~928** | | **~6,494** | | **~1.7 MB** |

At this volume, a single per-host OTel Collector would handle ~7K spans/day with ease. So why per-container?

### The Real Argument: Isolation and Autonomy, Not Performance

The per-container OTel sidecar is chosen for the same reason as the Vector sidecar: **operational isolation**.

1. **Independent lifecycle** -- Each sidecar is created/destroyed with its main container. No shared config to update, no global restart.
2. **Independent sampling** -- Patrol needs 100% sampling (critical ops data); cc-connect can use 10%. Per-sidecar config makes this trivial.
3. **Independent export tuning** -- High-volume services can batch more aggressively; low-volume services can export immediately.
4. **Failure isolation** -- A buggy OTel collector config for one service doesn't take down tracing for others.
5. **Self-contained deployment** -- Adding a new service to the cluster means adding one `depends_on` and one `network_mode` -- no central config changes.

### When to Reconsider Per-Host

- **Extreme resource constraints** (< 1 GB RAM per host). Each OTel Collector sidecar adds ~25 MB (configurable with `memory_limiter`). On a host with 15 containers, that's ~375 MB total for OTel alone.
- **Very high trace volume** (> 100K spans/sec). At that point, a dedicated per-host collector with horizontal scaling makes more sense. Not relevant at kyb's scale.

### Recommendation: Per-Container as Default, Per-Host as Exception

| Scenario | Pattern | Rationale |
|----------|---------|-----------|
| **Orbstack/Mac** (12+ services, 32 GB) | Per-container sidecar | Isolation, independent config, zero coupling |
| **Aliyun sim** (4-5 services, 2 GB) | Per-container sidecar (low overhead) or shared | Test both; ~100 MB overhead may be acceptable |
| **Office NUC8** (4-5 services, 8 GB) | Per-container sidecar | Comfortable resource headroom |
| **Massive scale** (> 100K spans/s) | Per-host + horizontal | Dedicated infra makes sense |

**Default decision: per-container OTel Collector sidecar.** This aligns with the existing Vector sidecar pattern and gives uniform treatment across all observability pillars.

---

## 3. Architecture

### 3.1 High-Level Diagram

```
┌──────────────────────────────────────────────────┐
│             docker-compose service                │
│                                                  │
│  ┌────────────────────┐  ┌────────────────────┐  │
│  │   Main Container   │  │  OTel Sidecar       │  │
│  │   (PG / Redis /    │  │  (otel/opentelemetry│  │
│  │    Kafka / cc-     │  │   -collector-       │  │
│  │    connect etc.)   │  │   contrib:0.117.0)  │  │
│  │                    │  │                     │  │
│  │  OTLP → localhost  │◄─┤  gRPC :4317        │  │
│  │  :4317/:4318       │  │  HTTP :4318        │  │
│  │                    │  │                     │  │
│  │  (auto-instr or    │  │  batch → central    │  │
│  │   manual OTel SDK) │  │  backends           │  │
│  └────────────────────┘  └──────┬──────────────┘  │
│                                 │                  │
└─────────────────────────────────┼──────────────────┘
                                  │ OTLP (gRPC)
                                  ▼
                    ┌─────────────────────────┐
                    │    Central Backends      │
                    │                         │
                    │  ┌───────────────────┐  │
                    │  │  Tempo (traces)   │  │
                    │  ├───────────────────┤  │
                    │  │  ClickHouse       │  │
                    │  │  (otel_spans)     │  │
                    │  ├───────────────────┤  │
                    │  │  Prometheus       │  │
                    │  │  (span metrics)   │  │
                    │  └───────────────────┘  │
                    └─────────────────────────┘
```

### 3.2 Network Namespace Sharing

The OTel sidecar uses `network_mode: "service:<target>"` (Docker Compose) or `--network container:<target>` (docker run) to share the target's network namespace. This means:

- The main container sends OTLP to `localhost:4317` (gRPC) or `localhost:4318` (HTTP).
- The sidecar listens on `0.0.0.0:4317` / `0.0.0.0:4318` inside the shared namespace.
- No port mapping needed -- the OTLP endpoint is local-only, not exposed externally.
- No network routing, no DNS, no SSL for the local hop.

### 3.3 Data Flow Per Sidecar

```
Instrumented App
     │
     │ OTLP via gRPC :4317 or HTTP :4318
     ▼
┌─────────────────────┐
│  OTel Collector      │
│  ┌─────────────────┐ │
│  │ otlp receiver    │ │
│  └────────┬────────┘ │
│           │          │
│  ┌────────▼────────┐ │
│  │ memory_limiter   │ │  Protect from OOM
│  └────────┬────────┘ │
│           │          │
│  ┌────────▼────────┐ │
│  │ batch processor  │ │  Configurable per service
│  └────────┬────────┘ │
│           │          │
│  ┌────────▼────────┐ │
│  │ attributes       │ │  Add service.name, cluster,
│  │ processor        │ │  container.id, sidecar version
│  └────────┬────────┘ │
│           │          │
│  ┌────────▼────────┐ │
│  │ sampling         │ │  Per-service sampling decision
│  └────────┬────────┘ │
│           │          │
│  ┌────────▼────────┐ │
│  │ OTLP exporter    │ │  → central tempo/ck/prometheus
│  │ (gRPC/HTTP)      │ │
│  └─────────────────┘ │
└─────────────────────┘
```

### 3.4 Sidecar Container Image

```yaml
image: otel/opentelemetry-collector-contrib:0.117.0
```

Why contrib (not core):
- **SpanMetrics connector** -- derive RED metrics from spans
- **ClickHouse exporter** -- native write to `otel_spans` table
- **Prometheus exporter** -- serve collector's own metrics
- **Memory limiter processor** -- prevent OOM
- **K8s attributes processor** -- (future) enrich with orchestration metadata

The contrib image is ~150 MB (vs ~75 MB for core). At current scale, the extra ~75 MB per sidecar is acceptable (~1 GB total for 15 sidecars on Orbstack). If disk becomes a concern, the core image + only needed components can be built as a custom image.

---

## 4. OTel Collector Configuration

### 4.1 Base Config (shared across all sidecars)

```yaml
# /etc/otel/config.yaml -- base config included by per-service configs
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        # Max message size: 4 MB (default)
        max_recv_msg_size_mib: 4
      http:
        endpoint: 0.0.0.0:4318
        # CORS not needed -- localhost only
        cors:
          allowed_origins: []

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 48          # Hard limit: 48 MB per sidecar
    spike_limit_mib: 8     # Allow short spikes up to 56 MB
  batch:
    timeout: 1s            # Export every 1s even if batch is small
    send_batch_size: 512   # Or when 512 spans accumulated
    send_batch_max_size: 1024
  attributes:
    actions:
      - key: sidecar.type
        value: "otel"
        action: upsert
      - key: sidecar.version
        value: "0.117.0"
        action: upsert
      - key: sidecar.mode
        value: "per-container"
        action: upsert
  # Resource detection: enrich with host-level attributes
  resourcedetection:
    detectors: [env, system, docker]
    timeout: 2s
    override: false

exporters:
  otlp/tempo:
    endpoint: tempo.monitoring:4317
    tls:
      insecure: true
    sending_queue:
      enabled: true
      num_consumers: 2
      queue_size: 100
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

  otlp/clickhouse:
    endpoint: otel-clickhouse-gateway:4317      # Future: dedicated OTel→CK gateway
    tls:
      insecure: true
    sending_queue:
      enabled: true
      num_consumers: 2
      queue_size: 100
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: otel_sidecar
    resource_to_telemetry_conversion:
      enabled: true

  # Debug/fallback: write to stdout (for development)
  logging:
    verbosity: detailed       # Change to 'normal' in production
    sampling_initial: 5
    sampling_thereafter: 100

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, attributes, batch]
      exporters: [otlp/tempo, otlp/clickhouse, logging]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus, logging]
```

### 4.2 Per-Service Config Overrides

Each service gets a thin config that includes the base and adds service-specific overrides:

```yaml
# /etc/otel/overrides/cc-connect.yaml

# Override service name
processors:
  attributes:
    actions:
      - key: service.name
        value: "cc-connect"
        action: upsert
      - key: container.type
        value: "application"
        action: upsert

# cc-connect: lower latency, sample at 50%
processors:
  batch:
    timeout: 500ms           # Lower latency for interactive traces
    send_batch_size: 128
  probabilistic_sampler:
    hash_seed: 42
    sampling_percentage: 50   # 50% sampling for cc-connect

service:
  pipelines:
    traces:
      processors: [memory_limiter, resourcedetection, attributes, probabilistic_sampler, batch]
```

```yaml
# /etc/otel/overrides/patrol.yaml

processors:
  attributes:
    actions:
      - key: service.name
        value: "patrol"
        action: upsert
      - key: container.type
        value: "ops"
        action: upsert
  # Patrol: NO sampling -- every round is critical
  # batch is fine, but no sampler processor

service:
  pipelines:
    traces:
      processors: [memory_limiter, resourcedetection, attributes, batch]
```

```yaml
# /etc/otel/overrides/postgresql.yaml

processors:
  attributes:
    actions:
      - key: service.name
        value: "postgresql-16"
        action: upsert
      - key: container.type
        value: "infra"
        action: upsert
  # PG traces are low volume. No sampling.
  # Batch: quick export, small batches
  batch:
    timeout: 200ms
    send_batch_size: 16

service:
  pipelines:
    traces:
      processors: [memory_limiter, resourcedetection, attributes, batch]
```

### 4.3 Full Config Assembly

The sidecar startup copies the base config + per-service override into a merged config:

```bash
# /entrypoint.sh (run inside sidecar container)
# Merge base config with service override
yq eval-all '. as $item ireduce ({}; . * $item)' \
  /etc/otel/base.yaml \
  "/etc/otel/overrides/${SERVICE_NAME}.yaml" \
  > /etc/otel/merged.yaml

exec otelcol-contrib --config=/etc/otel/merged.yaml
```

Alternatively, for the initial rollout, skip the merge complexity and use a single per-service config file mounted directly:

```yaml
# docker-compose.yml fragment
services:
  cc-connect:
    # ... main service config

  otel-cc-connect:
    image: otel/opentelemetry-collector-contrib:0.117.0
    network_mode: "service:cc-connect"
    volumes:
      - ./otel/configs/cc-connect.yaml:/etc/otel/config.yaml:ro
    environment:
      - SERVICE_NAME=cc-connect
      - CLUSTER_NAME=${CLUSTER_NAME}
      - OTEL_COLLECTOR_MEMORY_LIMIT=64
    depends_on: [cc-connect]
```

This simpler approach avoids the yq merge step and is recommended for initial rollout.

---

## 5. Deployment Patterns

### 5.1 Docker Compose (Preferred)

```yaml
x-otel-sidecar: &otel-sidecar
  image: otel/opentelemetry-collector-contrib:0.117.0
  restart: unless-stopped
  environment:
    CLUSTER_NAME: "${CLUSTER_NAME}"
    OTEL_RESOURCE_ATTRIBUTES: "cluster=${CLUSTER_NAME}"
  cap_drop:
    - ALL               # Security: drop all capabilities
  read_only: true       # Security: read-only filesystem
  tmpfs:
    - /tmp:size=16m     # Small tmpfs for buffering
  logging:
    driver: "json-file"
    options:
      max-size: "5m"
      max-file: "2"

services:
  # --- PostgreSQL 16 ---
  postgres-16:
    image: postgres:16
    networks: [kyb-net]
    environment:
      # PG does not natively emit OTLP, so the sidecar only collects
      # from PG's Prometheus metrics endpoint (future: via OTel metrics receiver)
      ...

  otel-postgres-16:
    <<: *otel-sidecar
    network_mode: "service:postgres-16"
    volumes:
      - ./otel/configs/postgresql.yaml:/etc/otel/config.yaml:ro
    depends_on: [postgres-16]

  # --- cc-connect ---
  cc-connect:
    image: cc-connect:latest
    networks: [kyb-net]
    environment:
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://localhost:4317"
      OTEL_SERVICE_NAME: "cc-connect"
      ...

  otel-cc-connect:
    <<: *otel-sidecar
    network_mode: "service:cc-connect"
    volumes:
      - ./otel/configs/cc-connect.yaml:/etc/otel/config.yaml:ro
    depends_on: [cc-connect]

  # --- Patrol ---
  patrol-container:
    image: kyb-infra-boss:latest
    networks: [kyb-net]
    environment:
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://localhost:4317"
      ...

  otel-patrol:
    <<: *otel-sidecar
    network_mode: "service:patrol-container"
    volumes:
      - ./otel/configs/patrol.yaml:/etc/otel/config.yaml:ro
    depends_on: [patrol-container]
```

### 5.2 Standalone `docker run` (for Existing Services)

```bash
# Given: kyb-infra-cc-connect is already running
# Attach OTel sidecar sharing its network namespace

docker run -d \
  --name otel-cc-connect \
  --network container:kyb-infra-cc-connect \
  --pid container:kyb-infra-cc-connect \
  -v /home/dev/projects/kyb/infra/otel/configs/cc-connect.yaml:/etc/otel/config.yaml:ro \
  -e CLUSTER_NAME=mac-orbstack \
  -e OTEL_RESOURCE_ATTRIBUTES="cluster=mac-orbstack" \
  --restart unless-stopped \
  --cap-drop ALL \
  --read-only \
  --tmpfs /tmp:size=16m \
  otel/opentelemetry-collector-contrib:0.117.0
```

### 5.3 Batch Attach Script

```bash
# infra/observability/attach-otel-sidecars.sh
# Attach OTel sidecars to all running infra containers.

CLUSTER_NAME="${1:?Usage: $0 <cluster-name>}"

declare -A TARGETS=(
  ["kyb-infra-pg16"]="otel/configs/postgresql.yaml"
  ["kyb-infra-redis"]="otel/configs/redis.yaml"
  ["kyb-infra-kafka"]="otel/configs/kafka.yaml"
  ["kyb-infra-clickhouse"]="otel/configs/clickhouse.yaml"
  ["kyb-infra-cc-connect"]="otel/configs/cc-connect.yaml"
  ["kyb-infra-boss"]="otel/configs/patrol.yaml"
)

for container in "${!TARGETS[@]}"; do
  config="${TARGETS[$container]}"
  sidecar_name="otel-${container#kyb-infra-}"

  if docker ps --filter "name=$sidecar_name" --format '{{.Names}}' | grep -q "$sidecar_name"; then
    echo "SKIP: $sidecar_name already running"
    continue
  fi

  echo "==> Attaching $sidecar_name to $container..."

  docker run -d \
    --name "$sidecar_name" \
    --network "container:$container" \
    -v "$(pwd)/$config:/etc/otel/config.yaml:ro" \
    -e CLUSTER_NAME="$CLUSTER_NAME" \
    -e OTEL_RESOURCE_ATTRIBUTES="cluster=$CLUSTER_NAME" \
    --restart unless-stopped \
    --cap-drop ALL \
    --read-only \
    --tmpfs /tmp:size=16m \
    otel/opentelemetry-collector-contrib:0.117.0

  if [ $? -eq 0 ]; then
    echo "  OK"
  else
    echo "  FAILED"
  fi
done
```

### 5.4 Lifecycle Management

The OTel sidecar depends on its target container's network namespace. If the target restarts, the sidecar must be recreated:

```yaml
# docker-compose: depends_on ensures ordering
depends_on:
  postgres-16:
    condition: service_started   # Sidecar starts after target
```

For standalone `docker run`, a watch script detects target restarts:

```bash
# infra/observability/otel-sidecar-watch.sh
# Run from infra-boss cron (every 60s)
# Detect missing sidecars and re-attach

TARGETS="kyb-infra-pg16:otel-pg16 kyb-infra-redis:otel-redis ..."

for pair in $TARGETS; do
  MAIN="${pair%%:*}"
  SIDECAR="${pair##*:}"
  MAIN_RUNNING=$(docker ps --filter "name=$MAIN" --format '{{.Names}}' | grep -c "$MAIN")
  SIDECAR_RUNNING=$(docker ps --filter "name=$SIDECAR" --format '{{.Names}}' | grep -c "$SIDECAR")

  if [ "$MAIN_RUNNING" -gt 0 ] && [ "$SIDECAR_RUNNING" -eq 0 ]; then
    echo "Sidecar $SIDECAR missing for running target $MAIN, re-attaching..."
    # Re-run attach logic for this container
  fi
done
```

### 5.5 Upgrade

Zero-downtime upgrade of OTel sidecars:

```bash
# Pull new image first (avoids pulling during recreate)
docker pull otel/opentelemetry-collector-contrib:0.118.0

# Graceful shutdown: OTel Collector handles SIGTERM by flushing
# all in-flight spans before exiting.

for sidecar in $(docker ps --format '{{.Names}}' | grep '^otel-'); do
  echo "Upgrading $sidecar..."
  docker stop "$sidecar"    # SIGTERM → flush + exit
  sleep 2
  docker rm "$sidecar"
  docker run -d ... otel/opentelemetry-collector-contrib:0.118.0
  echo "  OK"
done
```

Vector's behavior differs: Vector does NOT flush on SIGTERM by default. Set `--signal SIGTERM` or use the API to trigger a graceful shutdown. This is handled in the sidecar-pattern.md Vector config.

---

## 6. Service Integration Matrix

### 6.1 How Each Service Sends OTLP

| Service | OTel Integration | Mechanism | OTLP Endpoint Config |
|---------|-----------------|-----------|---------------------|
| **cc-connect** | Manual OTel SDK (Go) | `tracer.Start()` in code | `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` |
| **Patrol (shell scripts)** | OTLP File Exporter → Vector | JSON Lines file → Vector → OTLP | `/tmp/otel-traces.jsonl` (file) |
| **PostgreSQL** | PG doesn't emit OTLP natively | Future: pg exporter → OTel metrics receiver in sidecar | N/A (sidecar just hosts the receiver) |
| **Redis** | Same as PG | Future: Redis exporter | N/A |
| **Kafka** | Kafka does not emit OTLP | Kafka exporter → OTel metrics | N/A |
| **ClickHouse** | CK does not emit OTLP | CK native Prometheus metrics → OTel metrics receiver | N/A |
| **Grafana** | Grafana exposes /metrics | OTel Prometheus receiver → scrape | `scrape://localhost:3000/metrics` |
| **sing-box** | No metrics endpoint | Vector + sidecar logs only | N/A (no trace instrumentation planned) |
| **Future Go services** | Manual OTel SDK | Standard OTLP gRPC | `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` |

### 6.2 OTel Sidecar Capabilities per Service

| Service | Traces | Metrics (from OTLP) | Metrics (scrape) | Logs |
|---------|--------|---------------------|-------------------|------|
| cc-connect | Full | From spans | N/A | Via Vector (separate) |
| Patrol | Full (file → Vector → sidecar OTLP receiver) | From spans | N/A | N/A |
| PostgreSQL | N/A (no trace source) | Future | Future: scrape PG exporter | Via Vector |
| Redis | N/A | Future | Future: scrape Redis exporter | Via Vector |
| Kafka | N/A | Future | Future: scrape Kafka exporter | Via Vector |
| ClickHouse | N/A | Future | Future: scrape CK /metrics | Via Vector (self-log) |
| Grafana | N/A | Future | Sidecar scrapes Grafana /metrics | Via Vector |

Key insight: **Not every service needs OTel traces.** For infra services (PG, Redis, Kafka, CK), the OTel sidecar primarily serves as a future OTel metrics receiver and pass-through for span metrics. The trace pipeline is idle until those services are OTel-instrumented.

### 6.3 Integration with Vector Sidecars

The OTel sidecar and Vector sidecar coexist on the same target container:

```
┌──────────────────────────────────────────────────┐
│              Target Container Network             │
│                                                  │
│  ┌──────────┐  ┌──────────────┐  ┌────────────┐ │
│  │  Main     │  │  OTel         │  │  Vector     │ │
│  │  Service  │  │  Collector    │  │  (logs +    │ │
│  │           │  │  (traces)     │  │   metrics)  │ │
│  │  OTLP →   │◄─┤  :4317/:4318 │  │            │ │
│  │  :4317    │  │              │  │            │ │
│  └──────────┘  └──────┬───────┘  └─────┬──────┘ │
│                        │                │        │
└────────────────────────┼────────────────┼────────┘
                         │                │
                         ▼                ▼
                   Central Tempo     Central CK
```

Each sidecar has a single responsibility:
- **OTel sidecar**: trace collection, batching, export to Tempo/CK
- **Vector sidecar**: log collection, VRL transform, export to CK
- **Future**: OTel metrics receiver pipeline in the OTel sidecar (replacing Prometheus exporter sidecars from `sidecar-pattern.md`)

---

## 7. Export Pipeline

### 7.1 Primary Export: Tempo

```
OTel Sidecar → OTLP gRPC → Tempo (port 4317)
```

Tempo is the primary trace store. It receives OTLP natively, provides trace-by-ID lookup, and integrates with Grafana as a datasource.

### 7.2 Secondary Export: ClickHouse

```
OTel Sidecar → OTLP gRPC → ClickHouse (otel_spans table)
```

ClickHouse serves as a long-term trace archive and enables SQL-powered trace analysis. The ClickHouse OTel exporter writes to a structured table:

```sql
CREATE TABLE IF NOT EXISTS infra.otel_spans (
  Timestamp DateTime64(9) CODEC(Delta, ZSTD),
  TraceId String CODEC(ZSTD),
  SpanId String CODEC(ZSTD),
  ParentSpanId String CODEC(ZSTD),
  TraceState String CODEC(ZSTD),
  SpanName String CODEC(ZSTD),
  SpanKind LowCardinality(String) CODEC(ZSTD),
  ServiceName String CODEC(ZSTD),
  ResourceAttributes String CODEC(ZSTD),   -- JSON
  ScopeName String CODEC(ZSTD),
  SpanAttributes String CODEC(ZSTD),       -- JSON
  Duration Int64 CODEC(ZSTD),              -- nanoseconds
  StatusCode LowCardinality(String) CODEC(ZSTD),  -- OK / ERROR / UNSET
  StatusMessage String CODEC(ZSTD),

  INDEX idx_trace_id TraceId TYPE bloom_filter GRANULARITY 1,
  INDEX idx_service ServiceName TYPE minmax GRANULARITY 1
) ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(Timestamp)
ORDER BY (ServiceName, Timestamp)
TTL Timestamp + INTERVAL 90 DAY;
```

This replicates the schema from `otel-mcp.md` section 6.3 and `otel-cc-connect.md` for uniformity.

### 7.3 Metrics Export: Prometheus / SpanMetrics

Each OTel sidecar exposes its own metrics on `:8889/metrics`:

```
otel_sidecar_spans_received_total{service_name="cc-connect"} 540
otel_sidecar_spans_exported_total{exporter="otlp/tempo"} 540
otel_sidecar_batch_size_histogram{bucket="...} ...
otel_sidecar_memory_usage_bytes 4194304
```

Additionally, the SpanMetrics connector (in contrib) can derive RED metrics from spans:

| Metric | Type | Source | Labels |
|--------|------|--------|--------|
| `traces_span_metrics_calls_total` | Counter | Span count | `service_name`, `span_name`, `status_code` |
| `traces_span_metrics_duration_milliseconds` | Histogram | Span duration | `service_name`, `span_name` |

These can be enabled in the sidecar config when needed.

### 7.4 Buffering and Backpressure

Each OTel sidecar has an independent sending queue:

```yaml
exporters:
  otlp/tempo:
    sending_queue:
      enabled: true
      num_consumers: 2       # Two concurrent export streams
      queue_size: 100        # Max 100 spans queued in memory
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s  # Give up after 5 minutes
```

If Tempo or ClickHouse is down:
1. Spans accumulate in the queue up to `queue_size` (100 spans).
2. If queue is full, the `memory_limiter` processor starts rejecting new spans (503 to the app).
3. The app's OTel SDK backs off and may drop spans (the app's own `BatchSpanProcessor` has a queue).
4. When backends recover, the sidecar drains its queue and normal operation resumes.

### 7.5 Fallback: Direct CK Write (No Tempo)

If Tempo is not deployed (e.g., on resource-constrained hosts), the sidecar can export directly to ClickHouse:

```yaml
exporters:
  clickhouse:
    endpoint: tcp://ckhost:9000
    database: infra
    table: otel_spans
    timeout: 5s
    sending_queue:
      enabled: true
      queue_size: 100

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, attributes, batch]
      exporters: [clickhouse, logging]
```

Tempo is preferred for interactive trace exploration (Grafana datasource). ClickHouse is the archive. For minimum infrastructure, go direct to ClickHouse.

---

## 8. Operational Concerns

### 8.1 Resource Overhead

Per sidecar:

| Resource | Value | Notes |
|----------|-------|-------|
| Image size | ~150 MB | `otel/opentelemetry-collector-contrib` |
| Memory (idle) | ~15 MB | No trace activity |
| Memory (active) | ~25-35 MB | At 1000 spans/min |
| Memory (peak) | ~56 MB | With `limit_mib: 48` + `spike_limit_mib: 8` |
| CPU (idle) | < 0.1% | Waiting for OTLP |
| CPU (active) | ~1-2% | Batching + exporting |
| Disk (tmpfs) | ~16 MB | Buffer during backend outage |

Times 15 services on Orbstack:
- Memory: ~375-525 MB total
- CPU: ~15-30% total (idle: negligible)
- Disk: ~240 MB images (shared layers)

This is acceptable on Orbstack (32 GB RAM, M-series CPU).

### 8.2 Security

| Concern | Mitigation |
|---------|------------|
| OTLP exposed | Sidecar listens on `0.0.0.0:4317` inside the shared network namespace. Only reachable by the target container. Not port-mapped to host. |
| Config injection | Config file mounted read-only (`:ro`). Sidecar container runs `read_only: true` and `cap_drop: ALL`. |
| Buffer data | `tmpfs` mount at `/tmp` -- in-memory only, no disk persistence. Data lost on sidecar stop (acceptable -- traces are expendable). |
| OTLP export mTLS | Not needed for localhost-to-central links in the same cluster. Future: mTLS for cross-cluster export. |

### 8.3 Health Check

```yaml
# If using the collector's own health check extension:
extensions:
  health_check:
    endpoint: 0.0.0.0:13133

service:
  extensions: [health_check]
```

```bash
# Docker health check
docker run ... \
  --health-cmd "wget -qO- http://localhost:13133/ | grep -q ServerOK" \
  --health-interval 10s \
  --health-retries 3 \
  --health-start-period 5s
```

### 8.4 Monitoring the Monitor

Each OTel sidecar exports its own metrics to Prometheus (`:8889/metrics`). Key metrics to alert on:

| Metric | Alert Condition | Meaning |
|--------|----------------|---------|
| `otelcol_exporter_queue_size` | > 50 for > 5 min | Export backend is slow or down |
| `otelcol_process_memory_rss` | > 40 MB | Memory leak or unexpected load |
| `otelcol_processor_dropped_spans` | > 0 | Sidecar dropping spans (queue full, memory limiter) |
| `up{container="otel-*"}` | == 0 | Sidecar container is down |
| `otelcol_receiver_accepted_spans{receiver="otlp"}` | Rate == 0 for > 10 min | No spans received -- is the main container sending? |

These are collected by Vector's `prometheus_scrape` source (from the Vector sidecar on the same target) or by a central Prometheus.

### 8.5 Debugging

```bash
# Check sidecar health
curl -s http://localhost:13133/health

# View sidecar logs (tail last 50 lines)
docker logs --tail 50 otel-cc-connect

# Check OTel collector metrics
curl -s http://localhost:8889/metrics | grep -E 'otelcol_receiver|otelcol_exporter'

# Check if spans are flowing
docker exec otel-cc-connect otelcol --dryrun  # Not a real flag; use logs
docker logs otel-cc-connect | grep -E 'TraceExporter|spans' | tail -20

# Trace a specific span
# Find trace_id in ClickHouse, then query Tempo
```

---

## 9. Comparison: Per-Container vs Per-Host OTel Collector

| Aspect | Per-Container (This Doc) | Per-Host (`sidecar-pattern.md`) |
|--------|-------------------------|-------------------------------|
| **Isolation** | Full -- one sidecar failure affects one service | Shared -- collector crash affects all services |
| **Config complexity** | N configs for N services | 1 config for all services |
| **Resource overhead** | ~25-35 MB per sidecar × N | ~50-80 MB total |
| **Sampling granularity** | Per-service independent | Single global sampling decision |
| **Export tuning** | Per-service batch/send_batch_size/queue | Single config must suit all |
| **Adding new service** | Add `depends_on` + `network_mode` + config mount | Edit central config + restart collector |
| **Startup ordering** | Must follow main container | Independent of any single container |
| **Upgrade risk** | One sidecar at a time, gradual rollout | Global restart (brief trace data loss) |
| **Single pane of glass** | Harder -- need to check N instances | Easier -- one health endpoint |
| **Suitable for** | 3+ services, heterogeneous trace volume | 1-2 services, homogeneous trace volume |

### Recommendation

**Default: Per-container** for all kyb infra deployments. The isolation benefits outweigh the resource overhead at kyb's scale.

**Use per-host only when:**
- Host has < 1 GB free RAM
- Only 1-2 services emit traces
- Trace volume is negligible (< 100 spans/day)

### Migration from Per-Host

If a per-host OTel Collector is already deployed (as described in `sidecar-pattern.md` section 3.3 and `otel-cc-connect.md`):

```bash
# Phase 1: Deploy per-container sidecars alongside per-host collector
# Phase 2: Move each service's OTLP endpoint from per-host to sidecar
#   - Change OTEL_EXPORTER_OTLP_ENDPOINT from per-host:4317 to localhost:4317
#   - No code change -- just env var change
# Phase 3: Remove per-host collector (or keep as fallback)
```

The per-host collector becomes a **fallback aggregator** -- services that don't yet have a sidecar continue sending to it.

---

## 10. Implementation Roadmap

### Phase 1: Foundation (0.5 day)

- [ ] Create per-service OTel collector configs in `infra/otel/configs/`
- [ ] Create base config with shared processors, exporters
- [ ] Write `attach-otel-sidecars.sh` bootstrap script
- [ ] Deploy to first target: `cc-connect` (already OTel-instrumented)
- [ ] Verify trace data arrives in Tempo and ClickHouse

### Phase 2: Rollout (0.5 day)

- [ ] Deploy sidecars to Patrol (shell → file → Vector → OTLP path)
- [ ] Deploy sidecars to infra services (PG, Redis, Kafka, CK, Grafana)
  - Initially as passive receivers (no trace sources emit OTLP yet)
  - Ready for future OTel instrumentation
- [ ] Update Docker Compose files for all services
- [ ] Add health check config to all sidecars

### Phase 3: Integration (1 day)

- [ ] Wire sidecar metrics into Prometheus (via Vector scrape or direct)
- [ ] Create Grafana dashboard: "OTel Sidecar Fleet View"
  - Per-sidecar health, span throughput, error rate, memory
- [ ] Add alert rules for sidecar health
- [ ] Write `otel-sidecar-watch.sh` for auto-recovery

### Phase 4: Optimization (ongoing)

- [ ] Tune per-service batch configs based on observed volume
- [ ] Evaluate `--read-only` + `tmpfs` impact on long-running sidecars
- [ ] Consider custom minimal OTel Collector image (trim contrib to needed components)
- [ ] Benchmark memory/CPU overhead and adjust `memory_limiter` values

### Phase 5: Future (when needed)

- [ ] Add OTel metrics receiver pipeline to sidecar (replace Prometheus exporter sidecars from `sidecar-pattern.md`)
- [ ] Cross-cluster OTLP export (sidecar on Aliyun → sidecar on Orbstack → Tempo)
- [ ] mTLS for cross-cluster OTLP gRPC

---

## Appendix A: Per-Service Config File Index

| Config File | Target Container | Sampling | Batch Timeout | Notes |
|------------|-----------------|----------|---------------|-------|
| `otel/configs/base.yaml` | (shared) | N/A | 1s | Base config included by all |
| `otel/configs/cc-connect.yaml` | `kyb-infra-cc-connect` | 50% | 500ms | Interactive, latency-sensitive |
| `otel/configs/patrol.yaml` | `kyb-infra-boss` | 100% | 1s | Critical ops data |
| `otel/configs/postgresql.yaml` | `kyb-infra-pg16` | 100% | 200ms | Low volume, quick export |
| `otel/configs/redis.yaml` | `kyb-infra-redis` | 100% | 200ms | Low volume |
| `otel/configs/kafka.yaml` | `kyb-infra-kafka` | 100% | 200ms | Low volume |
| `otel/configs/clickhouse.yaml` | `kyb-infra-clickhouse` | 100% | 200ms | Low volume |
| `otel/configs/grafana.yaml` | `kyb-infra-grafana` | 100% | 200ms | Low volume |

## Appendix B: Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLUSTER_NAME` | (required) | Cluster identifier |
| `OTEL_RESOURCE_ATTRIBUTES` | `cluster=${CLUSTER_NAME}` | Resource attributes for span enrichment |
| `SERVICE_NAME` | (per config) | Service name for attributes processor |
| `OTEL_COLLECTOR_MEMORY_LIMIT` | `48` | Memory limit in MiB |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://tempo.monitoring:4317` | Central Tempo endpoint |

## Appendix C: Related Documents

- General sidecar pattern: `docs/infra/reviews/sidecar-pattern.md`
- OTel for cc-connect: `docs/infra/reviews/otel-cc-connect.md`
- OTel for MCP: `docs/infra/reviews/otel-mcp.md`
- OTel for Patrol: `docs/infra/reviews/otel-patrol.md`
- Observability design overview: `docs/infra/observability-design.md`
- Multi-cluster architecture: `docs/infra/multi-cluster-boss-architecture.md`

---

> ／人◕ ‿‿ ◕人＼
