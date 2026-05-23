---
decision: 稍微有点不确定等专家再审一轮
---

# Unified OTel Architecture — All Infra Services

**Date:** 2026-05-23
**Status:** Design document
**Scope:** Single OTel collector receiving traces from cc-connect, patrol, boss, MCP, docker-event-watcher, and infra containers. Unified schema, shared ClickHouse storage, common identity model.

---

## Table of Contents

1. [Current State: Five Independent Designs](#1-current-state-five-independent-designs)
2. [Target Architecture: Unified OTel Pipeline](#2-target-architecture-unified-otel-pipeline)
3. [OTel Collector Deployment](#3-otel-collector-deployment)
4. [Unified Span Schema](#4-unified-span-schema)
5. [Service Identity Model](#5-service-identity-model)
6. [Per-Service Integration](#6-per-service-integration)
7. [Common Attributes](#7-common-attributes)
8. [ClickHouse Storage](#8-clickhouse-storage)
9. [Sampling Strategy](#9-sampling-strategy)
10. [Context Propagation](#10-context-propagation)
11. [Cross-Service Trace Correlation](#11-cross-service-trace-correlation)
12. [Grafana Integration](#12-grafana-integration)
13. [Alerting](#13-alerting)
14. [Client SDK Decisions by Language](#14-client-sdk-decisions-by-language)
15. [Deployment Plan](#15-deployment-plan)
16. [Cost Estimate](#16-cost-estimate)
17. [Decision Log](#17-decision-log)

---

## 1. Current State: Five Independent Designs

The infra has five OTel-related design documents, each solving one service's problem in isolation:

| Document | Service | Language | Context Propagation | Exporter |
|----------|---------|----------|-------------------|----------|
| `otel-cc-connect.md` | cc-connect | Go | W3C TraceContext (HTTP) | OTLP gRPC to collector |
| `otel-patrol.md` | 5-min patrol | Shell / Ruby | File-based (JSON Lines) | Vector file source -> CK |
| `otel-mcp.md` | MCP proxy | Any (proxy) | W3C TraceContext via JSON-RPC `_traceparent` | OTLP gRPC to collector |
| `docker-events.md` | Docker event watcher | Shell | None (fire-and-forget) | Direct HTTP POST to CK |
| `kafka-message-bus.md` | Event bus (Kafka) | Multi | Envelope schema | Kafka -> CK Kafka Engine |

**Problems solved by unification:**

1. **No shared collector** — patrol uses Vector to CK, cc-connect sends OTLP to collector, docker-events POSTs directly to CK. Three different pipelines for five services.
2. **No common identity** — each service has its own attribute namespace (`cc.*`, `patrol.*`, `mcp.*`). Cross-service correlation requires ad-hoc joins on non-standard keys.
3. **No cross-service traces** — a patrol that triggers a cc-connect health check, or a Docker event that correlates with a patrol anomaly, cannot be traced across services.
4. **Duplicated infrastructure** — every service that wants OTel needs its own SDK init, exporter, and retry logic.

---

## 2. Target Architecture: Unified OTel Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Mac/Orbstack (super-boss)                    │
│                                                                     │
│  ┌────────────┐   ┌───────────┐   ┌────────────┐                   │
│  │ cc-connect │   │   MCP     │   │  Infra     │                   │
│  │ (Go, OTLP) │   │  Proxy    │   │ Containers │                   │
│  │            │   │ (OTLP)    │   │ (OTLP)     │                   │
│  └──────┬─────┘   └─────┬─────┘   └──────┬─────┘                   │
│         │               │                │                          │
│         └───────────────┼────────────────┘                          │
│                         │  OTLP gRPC (localhost:4317)               │
│                         ▼                                           │
│              ┌─────────────────────┐                                │
│              │   OTel Collector    │  ←── patrol (file JSON Lines)  │
│              │   (otel-collector)  │  ←── docker-event-watcher      │
│              │                     │       (file JSON Lines)        │
│              │                     │  ←── boss heartbeats           │
│              │                     │       (file JSON Lines)        │
│              └──────────┬──────────┘                                │
│                         │                                           │
│          ┌──────────────┼──────────────┐                            │
│          ▼              ▼              ▼                            │
│   ┌──────────┐   ┌──────────┐   ┌──────────┐                       │
│   │ Tempo    │   │Prometheus│   │ClickHouse│                       │
│   │ (traces) │   │(metrics) │   │(logs +   │                       │
│   │          │   │          │   │ spans)   │                       │
│   └──────────┘   └──────────┘   └──────────┘                       │
│         │              │              │                             │
│         └──────────────┼──────────────┘                             │
│                        ▼                                            │
│                 ┌────────────┐                                      │
│                 │  Grafana   │                                      │
│                 │ (unified)  │                                      │
│                 └────────────┘                                      │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Remote Clusters (Aliyun, Office)                            │  │
│  │                                                              │  │
│  │  ┌──────────────┐   ┌──────────────────┐                    │  │
│  │  │docker-event- │   │  boss heartbeats  │                    │  │
│  │  │watcher (file)│   │  (file JSON Lines)│                    │  │
│  │  └──────┬───────┘   └────────┬─────────┘                    │  │
│  │         │                    │                               │  │
│  │         └────OTLP gRPC───────┘                               │  │
│  │                    │  (over Tailscale to super-boss)         │  │
│  │                    ▼                                         │  │
│  │         (forwards to super-boss OTel Collector)              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.1 Data Flow by Service

| Service | Production Method | Transport | Ingestion |
|---------|-----------------|-----------|-----------|
| **cc-connect** | OTel Go SDK -> OTLP gRPC | Localhost to collector | Collector -> Tempo + CK |
| **MCP Proxy** | OTel SDK -> OTLP gRPC | Localhost to collector | Collector -> Tempo + CK |
| **Patrol** | JSON Lines file -> OTel Collector `filelog` receiver | Local file | Collector -> Tempo + CK |
| **Docker event watcher** | JSON Lines file -> OTel Collector `filelog` receiver | Local file | Collector -> CK |
| **Boss heartbeats** | JSON Lines file -> OTel Collector `filelog` receiver | Local file | Collector -> CK |
| **Infra containers** | OTel SDK (auto-instrumentation) -> OTLP gRPC | Localhost to collector | Collector -> Tempo + CK |
| **Remote clusters** | OTel Collector agent -> OTLP gRPC to super-boss | Tailscale | Super-boss collector -> backends |

### 2.2 Pipeline Unification Benefits

- **Single collector** handles all OTLP ingestion, batching, retry, backpressure for all services.
- **Single ClickHouse table** for all spans (service_name disambiguates).
- **Single Prometheus endpoint** for all derived metrics.
- **Single Grafana datasource** for traces, metrics, and logs.
- **File-based services** (patrol, docker-events, heartbeats) use the OTel Collector's `filelog` receiver instead of writing directly to CK, gaining batching, retry, and schema validation.

---

## 3. OTel Collector Deployment

### 3.1 Container

```bash
docker run -d \
  --name kyb-infra-otel-collector \
  --restart unless-stopped \
  --network kyb-infra \
  -p 4317:4317 \
  -p 4318:4318 \
  -p 8889:8889 \
  -v otel-collector-config:/etc/otel \
  -v /tmp/otel-traces:/tmp/otel-traces \
  otel/opentelemetry-collector-contrib:latest \
  --config /etc/otel/collector.yaml
```

### 3.2 Collector Config

```yaml
# /etc/otel/collector.yaml
receivers:
  # OTLP from SDK-instrumented services (cc-connect, MCP proxy, infra containers)
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

  # File logs from shell-based services (patrol, docker-events, heartbeats)
  filelog/patrol:
    include: [/tmp/otel-traces/patrol/*.jsonl]
    start_at: beginning
    poll_interval: 500ms
    operators:
      - type: json_parser
        parse_to: body
      - type: remove
        field: attributes["log.file.name"]

  filelog/docker_events:
    include: [/tmp/otel-traces/docker/*.jsonl]
    start_at: beginning
    poll_interval: 500ms
    operators:
      - type: json_parser
        parse_to: body

  filelog/heartbeats:
    include: [/tmp/otel-traces/boss/*.jsonl]
    start_at: beginning
    poll_interval: 500ms
    operators:
      - type: json_parser
        parse_to: body

  # Prometheus scrape for infrastructure targets
  prometheus/infra:
    config:
      scrape_configs:
        - job_name: 'otel-collector'
          scrape_interval: 15s
          static_configs:
            - targets: ['0.0.0.0:8888']

processors:
  batch:
    timeout: 2s
    send_batch_size: 8192

  memory_limiter:
    check_interval: 1s
    limit_mib: 1024

  # Enrich all spans with common attributes
  attributes/common:
    actions:
      - key: infra.service_version
        value: "${SERVICE_VERSION}"
        action: upsert
      - key: infra.hostname
        from_attribute: host.name
        action: upsert
      - key: infra.environment
        value: "production"
        action: upsert

  # Normalize file-based traces into proper OTel span format
  transform/patrol_to_spans:
    error_mode: ignore
    trace_statements:
      - context: log
        statements:
          - set(severity_text, body["severity"]) where body["severity"] != nil
          - set(attributes["patrol.round.id"], body["patrol_round_id"]) where body["patrol_round_id"] != nil
          - set(attributes["patrol.round.status"], body["status"]) where body["status"] != nil

  # Sampling decisions
  probabilistic_sampler:
    hash_seed: 42
    sampling_percentage: 100.0   # Current volume is tiny; overrides per-service via tail sampling

  tail_sampling:
    decision_wait: 30s
    num_traces: 10000
    expected_new_traces_per_sec: 10
    policies:
      # Always sample errors
      - name: error-policy
        type: status_code
        config:
          status_code_source: status_code
          status_codes:
            - ERROR
      # Always sample slow traces
      - name: latency-policy
        type: latency
        config:
          threshold_ms: 30000
      # Always sample patrol and docker-events (low volume)
      - name: patrol-policy
        type: string_attribute
        config:
          key: service.name
          values: [patrol, docker-event-watcher, boss-heartbeat]
          min_number_of_values_to_match: 1

exporters:
  # Tempo for trace storage and query
  otlp/tempo:
    endpoint: tempo.monitoring:4317
    tls:
      insecure: true

  # Prometheus for metrics derived from spans
  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: infra

  # ClickHouse for spans (via OTel ClickHouse exporter)
  clickhouse/infra:
    endpoint: tcp://host.orb.internal:9000
    database: infra
    ttl_days: 90
    traces_table_name: otel_spans
    logs_table_name: otel_logs

  # Debug / stdout for development
  debug:
    verbosity: basic
    sampling_initial: 5
    sampling_thereafter: 200

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, attributes/common, batch, tail_sampling]
      exporters: [otlp/tempo, clickhouse/infra, prometheus]

    traces/patrol:
      receivers: [filelog/patrol]
      processors: [memory_limiter, transform/patrol_to_spans, batch]
      exporters: [otlp/tempo, clickhouse/infra]

    traces/docker:
      receivers: [filelog/docker_events]
      processors: [memory_limiter, batch]
      exporters: [clickhouse/infra]

    traces/heartbeats:
      receivers: [filelog/heartbeats]
      processors: [memory_limiter, batch]
      exporters: [clickhouse/infra]

    metrics:
      receivers: [otlp, prometheus/infra]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
```

### 3.3 Remote Cluster Collector Agent

On remote clusters (Aliyun, Office), a lightweight OTel Collector agent runs inside `kyb-infra-boss`:

```yaml
# /etc/otel/agent.yaml
receivers:
  filelog/docker_events:
    include: [/tmp/otel-traces/docker/*.jsonl]
    poll_interval: 500ms
    operators:
      - type: json_parser
        parse_to: body
  filelog/heartbeats:
    include: [/tmp/otel-traces/boss/*.jsonl]
    poll_interval: 500ms
    operators:
      - type: json_parser
        parse_to: body

processors:
  batch:
    timeout: 5s
    send_batch_size: 1024
  attributes/common:
    actions:
      - key: infra.cluster
        value: "${CLUSTER_NAME}"
        action: upsert

exporters:
  otlp/superboss:
    endpoint: 100.104.244.99:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [filelog/docker_events, filelog/heartbeats]
      processors: [batch, attributes/common]
      exporters: [otlp/superboss]
```

---

## 4. Unified Span Schema

All services share a common span schema. Service-specific attributes live in their own namespace (`cc.*`, `patrol.*`, etc.), but the **structural schema** is identical.

### 4.1 Schema Table

```
field                   type        always      description
─────────────────────────────────────────────────────────────
timestamp               DateTime64  yes         Span start time (ns precision)
trace_id                String      yes         W3C TraceContext trace ID (32 hex chars)
span_id                 String      yes         W3C TraceContext span ID (16 hex chars)
parent_span_id          String      yes*        Empty string for root spans
trace_state             String      no          W3C TraceContext tracestate (vendors)
span_name               String      yes         Dot-separated: "<domain>.<component>.<action>"
span_kind               String      yes         INTERNAL | SERVER | CLIENT | PRODUCER | CONSUMER
service_name            String      yes         Canonical service name (see §5)
service_version         String      no          Git SHA or semver of the service
infra.cluster           String      yes         mac-orbstack | aliyun | office | volcano
infra.hostname          String      yes         Hostname or container ID
infra.environment       String      yes         production | staging | debug
duration_ns             Int64       yes         Span duration in nanoseconds
status_code             String      yes         OK | ERROR | UNSET
status_message          String      no          Error description (only on ERROR spans)
span_attributes         JSON        yes         Service-specific attributes as JSON
resource_attributes     JSON        no          OTel resource attributes (merged)
events                  JSON        no          Array of {name, timestamp, attributes} objects
links                   JSON        no          Array of {trace_id, span_id, attributes} objects

* parent_span_id is an empty string for root spans, not NULL.
```

### 4.2 Span Naming Convention

Every span name follows: `<domain>.<component>.<action>`

| Domain | Component | Action | Example |
|--------|-----------|--------|---------|
| `feishu` | `message` | `receive` | `feishu.message.receive` |
| `feishu` | `message` | `send` | `feishu.message.send` |
| `cc` | `message` | `route` | `cc.message.route` |
| `cc` | `agent` | `process` | `cc.agent.process` |
| `cc` | `tool` | `execute` | `cc.tool.execute` |
| `cc` | `permission` | `request` | `cc.permission.request` |
| `claude` | `api` | `call` | `claude.api.call` |
| `patrol` | `round` | (root) | `patrol.round` |
| `patrol` | `dispatch` | | `patrol.dispatch` |
| `patrol` | `check` | `docker` | `patrol.check.docker` |
| `patrol` | `heartbeat` | | `patrol.heartbeat` |
| `patrol` | `report` | | `patrol.report` |
| `mcp` | `request` | (root) | `mcp.request` |
| `mcp` | `transport` | `send` | `mcp.transport.send` |
| `mcp` | `tool` | `execute` | `mcp.tool.execute` |
| `docker` | `event` | | `docker.event` |
| `boss` | `heartbeat` | | `boss.heartbeat` |

### 4.3 Status Code Semantics (Unified)

| Status | Meaning | Examples |
|--------|---------|---------|
| `OK` | Completed successfully | Normal message turn, patrol passed, MCP call returned |
| `ERROR` | Failed or crashed | Claude API returned 5xx, patrol dispatch timed out, MCP tool threw exception |
| `UNSET` | Incomplete or unknown | Permission request awaiting resolution, patrol step skipped due to prior failure |

---

## 5. Service Identity Model

### 5.1 Canonical Service Names

Every span MUST carry `service.name` exactly as listed below (case-sensitive):

| `service.name` | Description | Source Language | SDK Instrumentation |
|----------------|-------------|-----------------|---------------------|
| `cc-connect` | Feishu WebSocket bridge | Go | Manual OTel Go SDK |
| `mcp-proxy` | MCP proxy sidecar | Go / Python | Manual OTel SDK |
| `patrol` | 5-minute patrol system | Shell / Ruby | File-based JSON Lines |
| `docker-event-watcher` | Docker event monitor | Shell | File-based JSON Lines |
| `boss-heartbeat` | Per-cluster heartbeat | Shell | File-based JSON Lines |
| `infra-container` | Generic infra container | Various | OTel auto-instrumentation or manual |

### 5.2 Resource Attributes (All Services)

Every telemetry source enriches data with:

```yaml
resource_attributes:
  service.name:          "<from table above>"
  service.version:       "<git sha or semver>"
  infra.cluster:         "mac-orbstack | aliyun | office"
  infra.hostname:        "<container hostname>"
  infra.environment:     "production"
  infra.container_id:    "<docker container ID (12 chars)>"
  infra.boss_id:         "<boss hostname>"    # set when running inside infra-boss
```

### 5.3 How Each Service Sets Identity

| Service | `service.name` set by | `infra.cluster` set by | `infra.hostname` set by |
|---------|-----------------------|----------------------|------------------------|
| cc-connect | OTel SDK resource | Env var `CLUSTER_NAME` | `os.Hostname()` |
| MCP proxy | OTel SDK resource | Env var `CLUSTER_NAME` | `os.Hostname()` |
| Patrol | File log header field | First line of JSONL file | `$(hostname)` in script |
| Docker event watcher | File log header field | Env var `CLUSTER_NAME` | `$(hostname)` in script |
| Boss heartbeat | File log header field | Env var `CLUSTER_NAME` | `$(hostname)` in script |
| Remote collector agent | N/A (added by processor) | Configured in agent.yaml | `$(hostname)` |

### 5.4 Service Discovery via Grafana

With unified `service.name` and `infra.cluster`, Grafana variables provide cross-service filtering:

```sql
-- Dropdown: all services
SELECT DISTINCT service_name FROM infra.otel_spans

-- Dropdown: all clusters
SELECT DISTINCT infra.cluster FROM infra.otel_spans

-- Time series: errors by service
SELECT toStartOfHour(timestamp) AS t, service_name, countIf(status_code='ERROR') AS errors
FROM infra.otel_spans
WHERE timestamp >= now() - INTERVAL 1 DAY
GROUP BY t, service_name
ORDER BY t
```

---

## 6. Per-Service Integration

### 6.1 cc-connect (Go, OTLP gRPC)

As designed in `otel-cc-connect.md`. Key integration points:

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/resource"
    "go.opentelemetry.io/otel/semconv/v1.26.0"
)

func initOTel() {
    ctx := context.Background()
    exporter, _ := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint("localhost:4317"),
        otlptracegrpc.WithInsecure(),
    )
    res, _ := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName("cc-connect"),
            semconv.ServiceVersion(version),
            attribute.String("infra.cluster", os.Getenv("CLUSTER_NAME")),
            attribute.String("infra.hostname", hostname),
        ),
    )
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(res),
    )
    otel.SetTracerProvider(tp)
}
```

No changes needed from the existing design. The collector endpoint is `localhost:4317`.

### 6.2 MCP Proxy (Go / Python, OTLP gRPC)

As designed in `otel-mcp.md`. The proxy sends OTLP to `localhost:4317`:

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource

resource = Resource.create({
    "service.name": "mcp-proxy",
    "service.version": version,
    "infra.cluster": os.getenv("CLUSTER_NAME", "unknown"),
    "infra.hostname": socket.gethostname(),
})
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint="localhost:4317", insecure=True)))
trace.set_tracer_provider(provider)
```

### 6.3 Patrol (Shell / Ruby, File-Based JSON Lines → Collector)

**Before (current design):** Patrol writes JSON Lines to `/tmp/otel-traces.jsonl`, Vector reads and sends to CK.

**After (unified):** Patrol writes structured span records to `/tmp/otel-traces/patrol/` directory. OTel Collector's `filelog` receiver picks them up.

**Patrol span record format:**

```json
{
  "timestamp": "2026-05-23T12:00:00.000000000Z",
  "trace_id": "0af7651916cd43dd8448eb211c80319c",
  "span_id": "b7ad6b7169203331",
  "parent_span_id": "",
  "span_name": "patrol.round",
  "span_kind": "INTERNAL",
  "service_name": "patrol",
  "infra": {
    "cluster": "mac-orbstack",
    "hostname": "infra-boss"
  },
  "attributes": {
    "patrol.round.id": "patr_01J2AB...",
    "patrol.round.number": 1,
    "patrol.round.status": "ok",
    "patrol.round.agent_id": "boss-claude-1"
  },
  "duration_ns": 35000000000,
  "status_code": "OK"
}
```

**Patrol sub-span example:**

```json
{
  "timestamp": "2026-05-23T12:00:01.000000000Z",
  "trace_id": "0af7651916cd43dd8448eb211c80319c",
  "span_id": "def4567890123456",
  "parent_span_id": "b7ad6b7169203331",
  "span_name": "patrol.check.docker",
  "span_kind": "INTERNAL",
  "service_name": "patrol",
  "attributes": {
    "docker.containers_running": 12,
    "docker.containers_expected": 12,
    "docker.containers_dead": 0
  },
  "duration_ns": 2000000000,
  "status_code": "OK"
}
```

**Patrol script template (simplified):**

```bash
#!/bin/bash
# patrol-span.sh -- write a span record to the OTel filelog directory

PATROL_DIR="/tmp/otel-traces/patrol"
mkdir -p "$PATROL_DIR"

write_span() {
  local trace_id="$1" span_id="$2" parent_span_id="$3" span_name="$4"
  local duration_ns="$5" status="$6"
  shift 6
  # Remaining args are key=value attributes

  local attrs="{"
  local first=true
  for kv in "$@"; do
    $first || attrs+=", "
    key="${kv%%=*}"
    val="${kv#*=}"
    # Determine type: if numeric, no quotes
    if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      attrs+="\"$key\": $val"
    else
      attrs+="\"$key\": \"$val\""
    fi
    first=false
  done
  attrs+="}"

  cat >> "$PATROL_DIR/round-$trace_id.jsonl" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)",
  "trace_id": "$trace_id",
  "span_id": "$span_id",
  "parent_span_id": "$parent_span_id",
  "span_name": "$span_name",
  "span_kind": "INTERNAL",
  "service_name": "patrol",
  "infra": {"cluster": "${CLUSTER_NAME:-unknown}", "hostname": "$(hostname)"},
  "attributes": $attrs,
  "duration_ns": $duration_ns,
  "status_code": "$status"
}
EOF
}
```

### 6.4 Docker Event Watcher (Shell, File-Based JSON Lines → Collector)

**Before (current design):** POSTs directly to ClickHouse via HTTP.

**After (unified):** Writes JSON Lines to `/tmp/otel-traces/docker/`. Collector uses `filelog` receiver.

**Docker event record format (not a span -- a log record):**

```json
{
  "timestamp": "2026-05-23T12:00:00.000000000Z",
  "observed_timestamp": "2026-05-23T12:00:01.000000000Z",
  "severity_text": "INFO",
  "body": "container:die on kyb-infra-cc-connect (exit_code=137)",
  "service_name": "docker-event-watcher",
  "infra": {
    "cluster": "mac-orbstack",
    "hostname": "infra-boss"
  },
  "attributes": {
    "docker.event_type": "container:die",
    "docker.container_name": "kyb-infra-cc-connect",
    "docker.actor_id": "abc123def456",
    "docker.image": "kyb-cc-connect:latest",
    "docker.exit_code": 137,
    "docker.oom_killed": true
  }
}
```

**Why log records not spans for Docker events:**
- Docker events are fire-and-forget observations, not request-scoped operations.
- They do not form a trace tree (no parent-child relationship).
- They are correlated by container identity, not trace context.
- Using log records avoids polluting the trace pipeline with millions of health check events per day.

The collector routes docker-event log records to ClickHouse `infra.otel_logs` table, not to Tempo.

### 6.5 Boss Heartbeat (Shell, File-Based JSON Lines → Collector)

**Before (current design):** Direct `curl` to CK HTTP endpoint.

**After (unified):** Writes JSON Lines to `/tmp/otel-traces/boss/`. Collector forwards to CK via `clickhouse/infra` exporter.

**Heartbeat record format:**

```json
{
  "timestamp": "2026-05-23T12:00:00.000000000Z",
  "service_name": "boss-heartbeat",
  "infra": {
    "cluster": "aliyun",
    "hostname": "kyb-infra-boss"
  },
  "attributes": {
    "boss.id": "aliyun-boss",
    "boss.cluster": "aliyun",
    "boss.docker_running": 12,
    "boss.docker_total": 15,
    "boss.disk_used_pct": 72.3,
    "boss.mem_used_pct": 45.0,
    "boss.load_1m": 1.2,
    "boss.uptime_seconds": 86400
  }
}
```

### 6.6 Remote Cluster Forwarding

On Aliyun and Office, `kyb-infra-boss` runs a lightweight OTel Collector agent that:
1. Reads file-based logs from `/tmp/otel-traces/docker/` and `/tmp/otel-traces/boss/`.
2. Forwards everything to the super-boss collector via OTLP gRPC over Tailscale.
3. Sets `infra.cluster` attribute on all forwarded spans.

---

## 7. Common Attributes

### 7.1 Infrastructure Attributes (Every Span / Log Record)

| Attribute | Type | Always? | Description | Example |
|-----------|------|---------|-------------|---------|
| `infra.cluster` | string | yes | Cluster name | `mac-orbstack` |
| `infra.hostname` | string | yes | Hostname or container name | `kyb-infra-boss` |
| `infra.environment` | string | yes | Deployment environment | `production` |
| `infra.container_id` | string | if available | Docker container ID (12 chars) | `abc123def456` |
| `infra.boss_id` | string | if inside boss | Boss container hostname | `kyb-infra-boss` |
| `infra.service_version` | string | if available | Git SHA or semver | `c1dff06` |

### 7.2 Cross-Cutting Attributes

| Attribute | Type | Used By | Description |
|-----------|------|---------|-------------|
| `session_id` | string | cc-connect, patrol | Unified session or turn identifier |
| `correlation_id` | string | All (optional) | External correlation key (e.g., Feishu message ID) |
| `error.type` | string | All (on error) | Error category for grouping |
| `error.message` | string | All (on error) | Human-readable error description |

### 7.3 Namespace Convention

Each service uses its own attribute namespace to avoid collisions:

| Namespace | Service | Example Attributes |
|-----------|---------|-------------------|
| `feishu.*` | cc-connect | `feishu.msg_id`, `feishu.chat_id`, `feishu.sender_id` |
| `cc.*` | cc-connect | `cc.session`, `cc.agent_session`, `cc.turn_count` |
| `claude.*` | cc-connect | `claude.request.model`, `claude.response.input_tokens` |
| `patrol.*` | patrol | `patrol.round.id`, `patrol.round.status`, `patrol.check.checks_passed` |
| `mcp.*` | MCP proxy | `mcp.server`, `mcp.tool`, `mcp.request_id`, `mcp.transport` |
| `docker.*` | docker-event-watcher | `docker.event_type`, `docker.container_name`, `docker.exit_code` |
| `boss.*` | boss-heartbeat | `boss.id`, `boss.cluster`, `boss.docker_running` |

---

## 8. ClickHouse Storage

### 8.1 Unified Spans Table

All spans from all services land in a single table:

```sql
CREATE TABLE infra.otel_spans (
    timestamp           DateTime64(9),
    trace_id            String,
    span_id             String,
    parent_span_id      String,
    trace_state         String,
    span_name           String,
    span_kind           LowCardinality(String),
    service_name        LowCardinality(String),
    service_version     String,
    infra_cluster       LowCardinality(String),
    infra_hostname      String,
    infra_environment   LowCardinality(String), 
    duration_ns         Int64,
    status_code         LowCardinality(String),
    status_message      String,
    span_attributes     JSON,
    resource_attributes JSON,
    events              JSON,
    links               JSON,

    -- Ingestion metadata
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service_name, infra_cluster, timestamp)
TTL timestamp + INTERVAL 90 DAY;
```

**Design decisions:**

1. **PARTITION BY month** — enables partition pruning for time-range queries. 90-day TTL drops old partitions cleanly.
2. **ORDER BY `(service_name, infra_cluster, timestamp)`** — the three most common query filters: which service, which cluster, when.
3. **JSON type for attributes** — ClickHouse 24.2+ supports native JSON column type with sub-column pushdown.
4. **LowCardinality for service_name, infra_cluster, infra_environment** — few distinct values, high compression ratio.
5. **TTL 90 days** — matches all existing retention policies.

### 8.2 Unified Logs Table

For non-span records (docker events, heartbeats, patrol log entries):

```sql
CREATE TABLE infra.otel_logs (
    timestamp           DateTime64(9),
    observed_timestamp  DateTime64(9),
    severity_text       LowCardinality(String),
    severity_number     UInt8,
    body                String,
    service_name        LowCardinality(String),
    infra_cluster       LowCardinality(String),
    infra_hostname      String,
    attributes          JSON,

    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service_name, infra_cluster, timestamp)
TTL timestamp + INTERVAL 90 DAY;
```

### 8.3 Storage Estimates

| Source | Records/day | Type | Daily Volume | 90-day Total |
|--------|-------------|------|-------------|--------------|
| cc-connect traces | ~540 spans | spans | ~108 KB | ~9.7 MB |
| MCP traces | ~150 spans | spans | ~30 KB | ~2.7 MB |
| Patrol traces | ~864 spans | spans | ~432 KB | ~38.9 MB |
| Docker events (no healthcheck) | ~50 records | logs | ~10 KB | ~0.9 MB |
| Docker events (with healthcheck) | ~46,000 records | logs | ~9.2 MB | ~828 MB |
| Boss heartbeats | ~1,440 records | logs | ~288 KB | ~25.9 MB |
| **Total (with healthcheck)** | **~49,044 records/day** | | **~10.1 MB/day** | **~906 MB** |

Even with full HEALTHCHECK on all infra containers, storage is under 1 GB for 90 days. ClickHouse compression (5-8x) reduces this to ~100-180 MB.

---

## 9. Sampling Strategy

### 9.1 By Service

| Service | Volume | Strategy | Rationale |
|---------|--------|----------|-----------|
| **cc-connect** | ~540 spans/day | 100% sample (no sampling) | Tiny volume; every trace is valuable |
| **MCP** | ~150 spans/day | 100% sample | Tiny volume |
| **Patrol** | ~864 spans/day | 100% sample | Low volume; every patrol round matters |
| **Docker events (no healthcheck)** | ~50/day | 100% sample | Trivial volume |
| **Docker events (with full healthcheck)** | ~46,000/day | 10% head sample + 100% tail for error/latency | Healthcheck events are high-volume but low-signal individually |
| **Boss heartbeats** | ~1,440/day | 100% sample | Low volume; every heartbeat matters for uptime tracking |

### 9.2 Sampling Implementation

Sampling is applied at two levels:

**Head sampling (at source):**
- SDK-instrumented services (cc-connect, MCP proxy) use `TraceIDRatioBased` sampler:
  - Docker healthcheck events: 10% sampling rate
  - All other services: always sample (`ALWAYS_ON`)
- File-based services (patrol, docker-events, heartbeats): always write (no sampling at source)

**Tail sampling (on OTel Collector):**
- Catch errors and slow traces that head sampling might miss:
```yaml
tail_sampling:
  policies:
    - name: always-errors
      type: status_code
      config: { status_code_source: status_code, status_codes: [ERROR] }
    - name: always-slow
      type: latency
      config: { threshold_ms: 30000 }
    - name: low-volume-services
      type: string_attribute
      config:
        key: service_name
        values: [cc-connect, patrol, boss-heartbeat]
```

---

## 10. Context Propagation

### 10.1 Propagation Methods by Service

| Service | Method | Mechanism |
|---------|--------|-----------|
| cc-connect | W3C TraceContext | `traceparent` header on Claude API HTTP calls |
| MCP proxy | W3C TraceContext | `_traceparent` field in JSON-RPC (stdio), HTTP header (SSE) |
| Patrol | File-based trace_id | Trace ID generated at round start, passed as env var to sub-steps |
| Docker event watcher | None (log records) | No trace context; correlated by `docker.container_name` |
| Boss heartbeat | None (log records) | No trace context; correlated by `boss.id` and timestamp |

### 10.2 Cross-Service Trace Correlation (Manual Key-Based)

Full distributed tracing across services requires a correlation key. Since shell-based services cannot propagate W3C TraceContext, use a **correlation_id** attribute:

```yaml
# When patrol detects a cc-connect anomaly:
correlation_id: "patrol-round-1234-cc-healthcheck-failure"

# The manual cc-connect health check invocation logs:
correlation_id: "patrol-round-1234-cc-healthcheck-failure"
```

In Grafana, query for the correlation_id to see events across services:

```sql
-- Find all telemetry with a given correlation_id
SELECT timestamp, service_name, span_name, status_code
FROM infra.otel_spans
WHERE span_attributes.correlation_id = 'patrol-round-1234-cc-healthcheck-failure'
ORDER BY timestamp
```

### 10.3 Future: Baggage-Based Cross-Service Propagation

Once all services are SDK-instrumented, switch to W3C Baggage:

```
baggage: correlation_id=patrol-round-1234,cluster=mac-orbstack
```

This enables:
- Automatic propagation across service boundaries (cc-connect -> Claude API -> response).
- No manual key passing in scripts.
- All spans in a cross-service trace share the same `trace_id`.

For now, file-based services use the manual correlation_id approach. SDK services can start using baggage immediately for cc-connect -> MCP links.

---

## 11. Cross-Service Trace Correlation

### 11.1 Patrol ↔ Docker Events

When patrol detects a container crash, it can find the corresponding Docker event:

```sql
-- Docker events near the patrol anomaly
SELECT timestamp, attributes.docker.event_type, attributes.docker.container_name
FROM infra.otel_logs
WHERE service_name = 'docker-event-watcher'
  AND timestamp >= '2026-05-23T12:00:00Z'
  AND timestamp <= '2026-05-23T12:05:00Z'
  AND attributes.docker.exit_code > 0

-- Patrol round in the same time window
SELECT timestamp, span_name, attributes.patrol.round.status
FROM infra.otel_spans
WHERE service_name = 'patrol'
  AND timestamp >= '2026-05-23T12:00:00Z'
  AND timestamp <= '2026-05-23T12:05:00Z'
```

### 11.2 cc-connect ↔ Patrol

When patrol suspects cc-connect is down, it triggers a health check. The health check result correlates via:

```sql
-- Was cc-connect processing messages recently?
SELECT timestamp, span_name, status_code
FROM infra.otel_spans
WHERE service_name = 'cc-connect'
  AND timestamp >= now() - INTERVAL 5 MINUTE
ORDER BY timestamp DESC
LIMIT 10

-- Did patrol detect the same issue?
SELECT timestamp, span_name, attributes
FROM infra.otel_spans
WHERE service_name = 'patrol'
  AND timestamp >= now() - INTERVAL 5 MINUTE
  AND span_name IN ('patrol.check.health', 'patrol.report')
```

### 11.3 MCP ↔ cc-connect (Future)

If MCP servers call cc-connect tools, trace context can propagate via W3C TraceContext. The MCP proxy injects `traceparent` into the cc-connect HTTP request, creating a single trace spanning both services.

### 11.4 Unified Trace Dashboard Query

```sql
-- "Everything happening in the last 5 minutes" view
SELECT timestamp, service_name, span_name, status_code, duration_ns,
       substring(span_attributes::String, 1, 200) AS attrs_preview
FROM infra.otel_spans
WHERE timestamp >= now() - INTERVAL 5 MINUTE
ORDER BY timestamp DESC
```

---

## 12. Grafana Integration

### 12.1 Datasources

| Datasource | Purpose | Endpoint |
|------------|---------|----------|
| Tempo | Trace storage and search | `http://tempo.monitoring:3200` |
| Prometheus | Derived metrics | `http://prometheus.monitoring:9090` |
| ClickHouse | Spans table + logs table | `http://host.orb.internal:8123` |

### 12.2 Tempo Query (Trace Search)

**Search by span attributes:**
```
{service.name="cc-connect"} | status=error
{service.name="patrol"} | patrol.round.status="failed"
{infra.cluster="aliyun"}
```

**TraceQL examples:**
```
{ service.name="cc-connect" && span.status = ERROR }
{ service.name="patrol" && duration > 30s }
{ service.name="docker-event-watcher" }
```

### 12.3 Recommended Dashboards

**Dashboard 1: Unified Overview** (`infra-otel-overview`)

| Panel | Query | Description |
|-------|-------|-------------|
| Spans/sec | `rate(infra_otel_spans_total[5m])` | Overall span ingestion rate |
| Errors/sec | `rate(infra_otel_spans_error_total[5m])` | Error rate across all services |
| P50/P90/P99 latency | Histogram quantile over `duration_ns` | End-to-end latency by service |
| Active traces | `count(distinct trace_id)` in last 5min | Concurrent trace count |
| Spans by service | `count by(service_name)` | Volume breakdown |

**Dashboard 2: Service Details** (`infra-otel-<service>`)

One per service, filtered by `service_name`:
- Trace list (latest 50 traces)
- Error rate time series
- Latency distributions
- Service-specific attributes table

**Dashboard 3: Cluster Health** (`infra-otel-cluster`)

| Panel | Query | Description |
|-------|-------|-------------|
| Boss heartbeats | Table of `boss-heartbeat` records | Last heartbeat per cluster |
| Docker events | Table of `docker-event-watcher` records | Recent container lifecycle events |
| Patrol status | Latest `patrol.round` per cluster | Patrol round results |
| Cluster comparison | `count by(infra_cluster)` | Spans per cluster |

### 12.4 Trace-to-Logs Correlation

Linking Tempo traces to ClickHouse log records via `trace_id`:

```sql
-- Given a trace_id from Tempo:
SELECT * FROM infra.otel_logs
WHERE attributes.trace_id = '0af7651916cd43dd8448eb211c80319c'
ORDER BY timestamp
```

Configure Grafana to add a "Related logs" link from Tempo span view to ClickHouse.

### 12.5 Alerting Rules

Built on Prometheus metrics derived from spans:

| Rule | Expression | Severity | Description |
|------|-----------|----------|-------------|
| NoTracesFromService | `absent(infra_otel_spans_total{service_name="patrol"}[5m])` | P1 | Service stopped reporting traces |
| HighErrorRate | `rate(infra_otel_spans_error_total[5m]) / rate(infra_otel_spans_total[5m]) > 0.05` | P1 | >5% error rate across any service |
| MissingHeartbeats | `absent(infra_otel_logs_total{service_name="boss-heartbeat"}[3m])` | P1 | No heartbeats from any cluster |
| ClusterSilent | `absent(infra_otel_logs_total{infra_cluster="aliyun"}[10m])` | P2 | Cluster stopped reporting |
| TraceLatencySpike | `histogram_quantile(0.99, rate(infra_otel_spans_duration_bucket[5m])) > 30s` | P2 | P99 latency exceeds 30s |

---

## 13. Alerting

### 13.1 Unified Alert Topics

All alerts flow through Feishu via the existing patrol system (or cc-connect send):

| Condition | Alert | Action |
|-----------|-------|--------|
| Collector down | `infra_otel_spans_total == 0 for 5m` | Feishu P1 |
| Any service silent | `infra_otel_spans_total{service="X"} == 0 for 5m` | Feishu P1 |
| Error rate > 5% | `error_rate > 0.05 for 5m` | Feishu P1 |
| Disk > 80% (from heartbeats) | `boss.disk_used_pct > 80` | Feishu P2 |
| Cluster silent > 10m | No heartbeats from cluster X | Feishu P2 |
| Crash loop (from docker events) | `docker.exit_code > 0 AND restart_count > 3 in 5m` | Feishu P1 |

### 13.2 Alert Integration with Patrol

The 5-minute patrol system already sends Feishu messages. Add an OTel health check to patrol:

```bash
# In patrol script:
# Check OTel collector health
otel_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:13133/health 2>/dev/null || echo "000")
if [ "$otel_status" != "200" ]; then
  record_anomaly "critical" "otel" "OTel collector unhealthy (HTTP $otel_status)"
fi

# Check that spans are flowing
span_count=$(docker exec kyb-infra-otel-collector \
  otelcol_span_count 2>/dev/null || echo "0")
if [ "$span_count" -eq 0 ] && [ "$otel_status" = "200" ]; then
  record_anomaly "warning" "otel" "OTel collector healthy but no spans in last 5m"
fi
```

---

## 14. Client SDK Decisions by Language

### 14.1 Go (cc-connect, MCP Proxy)

| Aspect | Decision |
|--------|----------|
| SDK package | `go.opentelemetry.io/otel` v1.x |
| Trace exporter | OTLP gRPC (`otlptracegrpc`) |
| Metric exporter | OTLP gRPC (`otlpmetricgrpc`) |
| Propagator | W3C TraceContext (`go.opentelemetry.io/otel/propagation/tracecontext`) |
| Resource detection | Manual (set `service.name`, `infra.cluster`, `infra.hostname`) |
| Sampler | `AlwaysOn` (100%) for cc-connect; `TraceIDRatioBased(0.1)` for high-volume MCP |

### 14.2 Python (MCP Servers, Future)

| Aspect | Decision |
|--------|----------|
| SDK package | `opentelemetry-distro` + `opentelemetry-instrumentation` |
| Trace exporter | OTLP gRPC (`OTLPSpanExporter`) |
| Propagator | W3C TraceContext (default) |
| Resource detection | `Resource.create()` with explicit attributes |
| Auto-instrumentation | `opentelemetry-instrument` wrapper for HTTP/gRPC subcalls |

### 14.3 Shell (Patrol, Docker Event Watcher, Boss Heartbeat)

| Aspect | Decision |
|--------|----------|
| SDK package | None (JSON Lines file output) |
| Trace context | Manual `trace_id` / `span_id` generation via `uuidgen` / `openssl rand` |
| Export | OTel Collector `filelog` receiver |
| No sub-millisecond timing needed | `date +%s%N` is sufficient for 5-minute patrol granularity |

### 14.4 Ruby (Patrol's Ruby Components)

If patrol uses Ruby for the report step:

| Aspect | Decision |
|--------|----------|
| SDK package | `opentelemetry-sdk` gem |
| Trace exporter | OTLP gRPC (`OpenTelemetry::Exporter::OTLP::Exporter`) |
| Propagator | W3C TraceContext |
| Integration | Minimal: create spans and export via OTLP from Ruby patrol scripts |

---

## 15. Deployment Plan

### Phase 1: Collector Bootstrap (Day 1)

- [ ] Deploy OTel Collector container on Mac/Orbstack
- [ ] Create `infra.otel_spans` and `infra.otel_logs` tables in ClickHouse
- [ ] Verify collector health endpoint
- [ ] Add Tempo datasource in Grafana

### Phase 2: SDK Services Migration (Day 1-2)

- [ ] Point cc-connect OTLP exporter to `localhost:4317` (was collector on arbitrary endpoint)
- [ ] Point MCP proxy OTLP exporter to `localhost:4317`
- [ ] Verify spans appearing in Tempo and ClickHouse

### Phase 3: File-Based Services Migration (Day 2-3)

- [ ] Update patrol to write JSON Lines to `/tmp/otel-traces/patrol/` instead of direct CK POST
- [ ] Update docker-event-watcher to write JSON Lines to `/tmp/otel-traces/docker/`
- [ ] Update boss heartbeat script to write JSON Lines to `/tmp/otel-traces/boss/`
- [ ] Verify all three pipelines in Collector

### Phase 4: Remote Cluster Forwarding (Day 3-4)

- [ ] Deploy OTel Collector agent on Aliyun `kyb-infra-boss`
- [ ] Deploy OTel Collector agent on Office `kyb-infra-boss`
- [ ] Verify spans forwarded to super-boss over Tailscale
- [ ] Validate `infra.cluster` attribute is populated correctly

### Phase 5: Dashboards + Alerts (Day 4-5)

- [ ] Create Grafana dashboard: Unified OTel Overview
- [ ] Create Grafana dashboard: Per-Service Details (cc-connect, patrol, MCP)
- [ ] Create Grafana dashboard: Cluster Health (heartbeats, docker events)
- [ ] Configure Prometheus alerting rules
- [ ] Wire alert notifications to Feishu via cc-connect send

### Phase 6: Cleanup (Day 5)

- [ ] Remove direct CK POST paths from patrol, docker-event-watcher, boss heartbeat
- [ ] Remove Vector filelog source for patrol traces (if migrated)
- [ ] Verify no data loss by comparing new pipeline counts with old pipeline counts

---

## 16. Cost Estimate

| Component | CPU | Memory | Disk | Network |
|-----------|-----|--------|------|---------|
| OTel Collector (super-boss) | <0.1 core | ~256 MB | ~50 MB (config + buffer) | <100 KB/s |
| OTel Collector agent (per remote cluster) | <0.05 core | ~128 MB | ~10 MB | <10 KB/s |
| Tempo | <0.2 core | ~512 MB | ~100 MB (traces, 90d) | <50 KB/s |
| ClickHouse (otel_spans + otel_logs) | <0.1 core | ~256 MB (buffer) | ~180 MB (90d, compressed) | Negligible |
| Prometheus (derived from spans) | <0.05 core | ~128 MB | ~50 MB (WAL) | Negligible |

**Total additional infrastructure cost:** ~1.5 GB RAM, ~400 MB disk, <100 KB/s network. This is well within the existing Mac/Orbstack capacity.

---

## 17. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Single collector vs per-service collector | Single collector on super-boss (with remote agents for forwarding) | Fewer moving parts; all pipelines share batching, retry, and backpressure |
| Tempo vs Jaeger vs ClickHouse-native | Tempo for trace storage + ClickHouse for analytics | Tempo provides native OTLP support and Grafana integration; CK provides SQL queryability |
| JSON type vs String for attributes | ClickHouse JSON type (24.2+) | Native sub-column pushdown; no need for `JSONExtract` functions |
| File-based services: Vector vs OTel filelog receiver | OTel filelog receiver | Eliminates Vector dependency for OTel pipeline; OTel-native schema parsing |
| Remote clusters: agent vs direct to CK | OTel Collector agent -> Tailscale -> super-boss collector | Centralized management; easy to add processors (sampling, enrichment) on the super-boss |
| Sampling: head vs tail | Hybrid: head (100% for low-volume, 10% for healthcheck) + tail (errors and slow traces always) | Head sampling controls volume from source; tail sampling catches important traces that head sampling might miss |
| Cross-service correlation: trace_id vs correlation_id | correlation_id attribute (manual) until all services are SDK-instrumented | W3C TraceContext propagation requires SDK support; file-based services cannot propagate natively |
| Docker events: spans vs log records | Log records (not spans) | Docker events are observations, not request-scoped operations. Log records avoid polluting the trace pipeline with high-volume healthcheck events |

---

## Appendix A: Existing Design Document Mapping

| This Doc Section | Source Document(s) |
|-----------------|-------------------|
| cc-connect spans | `otel-cc-connect.md` §2 (Trace Model) |
| MCP spans | `otel-mcp.md` §3 (Span Model) |
| Patrol spans | `otel-patrol.md` §2 (Trace Model) |
| Docker events | `docker-events.md` §2 (Architecture, Event Types) |
| Heartbeats | `multi-cluster-boss-architecture.md` §2.4 (Heartbeat Protocol) |
| Kafka bus | `kafka-message-bus.md` (full design -- Kafka is orthogonal to OTel, as a transport layer for the event bus) |

## Appendix B: Relationship to Kafka Message Bus

The Kafka message bus (`kafka-message-bus.md`) is a separate but complementary system:

| Aspect | OTel Pipeline (This Doc) | Kafka Event Bus |
|--------|--------------------------|-----------------|
| Purpose | Distributed tracing, span storage, latency analysis | Reliable event streaming between producers and consumers |
| Data | Trace spans, log records | Business events (message received, anomaly detected) |
| Retention | 90 days in CK | 7 days in Kafka |
| Consumers | Tempo (UI), Prometheus (metrics), CK (analytics) | CK (Kafka Engine), future consumers |
| Replay | Via Tempo trace search | Kafka consumer offset reset |

**When to use OTel:** Debugging a slow message turn, finding why patrol failed, correlating a Docker crash with service degradation.

**When to use Kafka:** Streaming business events to ClickHouse for dashboards, building an anomaly event stream for future consumers, decoupling producers from CK availability.

Both systems can coexist: OTel for **operational observability** (is the system healthy? what broke?), Kafka for **business analytics** (how many messages per hour? what are the trends?).

---

## Appendix C: Quick Reference -- File Paths

| Item | Path |
|------|------|
| Collector config (super-boss) | `/etc/otel/collector.yaml` |
| Collector config (remote agent) | `/etc/otel/agent.yaml` |
| Patrol span output dir | `/tmp/otel-traces/patrol/` |
| Docker event output dir | `/tmp/otel-traces/docker/` |
| Boss heartbeat output dir | `/tmp/otel-traces/boss/` |
| Collector container name | `kyb-infra-otel-collector` |
| Tempo container name | `kyb-infra-tempo` |
| CK spans table | `infra.otel_spans` |
| CK logs table | `infra.otel_logs` |
| This document | `docs/infra/reviews/unified-otel.md` |
| Source cc-connect OTel design | `docs/infra/reviews/otel-cc-connect.md` |
| Source patrol OTel design | `docs/infra/reviews/otel-patrol.md` |
| Source MCP OTel design | `docs/infra/reviews/otel-mcp.md` |

---

> **Summary:** Five independent OTel designs are unified into a single pipeline with one collector, one ClickHouse schema, one service identity model, and one Grafana integration. Total infrastructure cost: ~1.5 GB RAM, ~400 MB disk. File-based services use OTel Collector's `filelog` receiver instead of direct CK POST. Remote clusters forward through lightweight agents over Tailscale. Cross-service correlation uses `correlation_id` until full W3C TraceContext propagation is available in shell-based services.

> ／人◕ ‿‿ ◕人＼
