---
decision: 现在就做
---

# Recommended Observability Stack for kyb Infra

**Date**: 2026-05-23
**Status**: Synthesis / Single Source of Truth
**Scope**: All cluster observability: interception, transport, storage, query

---

After 50+ review documents covering proxies, sidecars, log pipelines, message buses, OTel tracing, and dashboarding, this doc consolidates every decision into a single recommended stack. Each choice is justified against the alternatives considered, and the data flow is traced from source to Grafana.

---

## Table of Contents

1. [Stack Overview](#1-stack-overview)
2. [Layer 1: Interception (How Data Gets Out of Services)](#2-layer-1-interception)
3. [Layer 2: Collection & Routing (How Data Moves to Central Storage)](#3-layer-2-collection--routing)
4. [Layer 3: Transport & Buffer (How Data Survives Outages)](#4-layer-3-transport--buffer)
5. [Layer 4: Storage & Query (How Data Is Stored and Explored)](#5-layer-4-storage--query)
6. [Data Flow Diagram](#6-data-flow-diagram)
7. [Deployment Matrix per Cluster](#7-deployment-matrix-per-cluster)
8. [Migration Path from Current Ad-Hoc State](#8-migration-path)
9. [Appendix: Rejected Alternatives Summary](#9-appendix-rejected-alternatives)

---

## 1. Stack Overview

```
                     INTERCEPTION
    ┌────────────────────────────────────────────────────┐
    │ docker events  │  docker logs  │  OTel SDK  │  WS  │
    │ watcher        │  (stdout)     │  (metric/   │  MITM│
    │                │               │   trace)    │proxy │
    └───────┬────────┴──────┬────────┴──────┬──────┴──┬───┘
            │               │               │         │
            ▼               ▼               ▼         ▼
                     COLLECTION & ROUTING
    ┌────────────────────────────────────────────────────┐
    │  Grafana Alloy  (central/recommended unified agent)│
    │  or  Vector + OTel Collector  (fallback)           │
    │  or  Fluentd  (remote, resource-constrained)       │
    │                                                    │
    │  - Prometheus scrape  (metrics from exporters)     │
    │  - OTLP receive       (traces from SDK)            │
    │  - Docker log tail    (logs from containers)       │
    └───────────────────────┬────────────────────────────┘
                            │
                            ▼
                     TRANSPORT & BUFFER
    ┌────────────────────────────────────────────────────┐
    │              Redpanda (Kafka API)                   │
    │                                                     │
    │  Topics:  cc.events  |  patrol.events               │
    │           otel.spans  |  system.events              │
    │           docker.events  |  bridge.events (future)  │
    │                                                     │
    │  Retention: 7 days  |  Replay: CK downtime          │
    └───────────────────────┬─────────────────────────────┘
                            │
                            ▼
                     STORAGE & QUERY
    ┌────────────────────────────────────────────────────┐
    │  ClickHouse  (single telemetry lake)               │
    │                                                     │
    │  Tables: cc.message_log | patrol.event_log          │
    │          otel.span_log  | infra.docker_events       │
    │          boss_logs      | kyb.claude_hook_events    │
    │          boss_heartbeats                             │
    │                                                     │
    │  TTL: 30-90 days per table                          │
    └───────────────────────┬─────────────────────────────┘
                            │
                            ▼
                     QUERY & VISUALIZE
    ┌────────────────────────────────────────────────────┐
    │  Grafana  (ClickHouse datasource)                  │
    │                                                     │
    │  Dashboards: Infra Overview | cc-connect Messages   │
    │              Patrol Health   | Docker Events         │
    │              Trace Explorer  | Token Cost            │
    └─────────────────────────────────────────────────────┘
```

---

## 2. Layer 1: Interception

### 2.1 Decision Matrix

| Data Source | Chosen Method | Rejected Alternatives |
|---|---|---|
| Container lifecycle (start/die/OOM) | `docker events` watcher inside boss | eBPF (too complex), tcpdump (encrypted) |
| Application logs (cc-connect, boss, patrol) | Docker stdout -> `docker_logs` source | File tail (fragile), journald (overengineered) |
| Application traces (cc-connect OTel) | OTel SDK -> OTLP export | Manual slog parsing (no trace context), log-based correlation (lossy) |
| WebSocket frames (Feishu WS) | Optional MITM proxy (feishu-proxy) | tcpdump (TLS opaque), SOCKS5 (no intercept), inline cc-connect mod (tight coupling) |
| Prometheus metrics (PG, Redis, Kafka) | Per-service exporters (sidecar pattern) | Native endpoints only (not all services have them) |

### 2.2 Justification per Choice

#### Container Lifecycle: `docker events` watcher

**Chosen**: A lightweight shell script inside each `kyb-infra-boss` container subscribes to the Docker event stream and POSTs normalized JSON to ClickHouse. (~50 lines of bash + python3 inline, zero new infrastructure.)

**Why not alternatives**:
- **eBPF** (rejected in `docker-events.md` §Alternative): Requires kernel 5.3+, BPF programs, fragile across kernel updates. At 50 events/day per cluster, the complexity is unjustified.
- **tcpdump** (rejected in `proxy-intercept.md` §12 Alt 2): TLS encryption means only encrypted blobs are visible. Useless for payload inspection.
- **Prometheus cAdvisor** (not documented separately): Adds another container and metric format; Docker events are already JSON and trivially ingestible.

#### Application Logs: Docker stdout -> Vector/Alloy

**Chosen**: All infra containers emit structured (or semi-structured) logs to stdout. A collection agent reads via Docker socket. The agent parses, enriches with cluster metadata, and routes to the correct ClickHouse table.

**Why not alternatives**:
- **File tail** (`/var/lib/docker/containers/*/*-json.log`): Works but requires filesystem access and position file management. Docker socket is simpler and avoids filesystem coupling.
- **journald**: No systemd-journald in these containers; Docker's default `json-file` driver is already in use.
- **Native fluentd log driver**: Ties the container to a specific log driver; breaks `docker logs`. Our sidecar/daemon approach is non-invasive.

#### Application Traces: OTel SDK -> OTLP

**Chosen**: Go (cc-connect) uses the OTel Go SDK. Ruby (patrol) uses the OTel Ruby SDK or OTel API via HTTP export. Both export OTLP to a local collector.

**Why not alternatives**:
- **Manual slog parsing**: cc-connect already emits structured logs, but they lack trace context. You cannot correlate a "message received" event with its "turn complete" without an explicit trace_id. OTel provides this natively.
- **Log-based correlation**: You can correlate by `msg_id`, but this is a two-table JOIN and breaks across event types. OTel spans carry parent-child relationships natively.
- **No tracing**: Accepted for non-critical containers (PG, Redis, Kafka). Their behavior is well-understood and low-change. Only cc-connect and patrol benefit from tracing.

#### WebSocket Frames: Optional MITM Proxy

**Chosen**: A feishu-proxy binary (Go, ~5 MB) that sits between cc-connect and Feishu WS, forwarding frames bidirectionally and logging metadata to stdout. **Not always-on** -- deployed on-demand for deep debugging sessions.

**Why not alternatives**:
- **tcpdump**: TLS 1.3 renders PCAP opaque. Only packet sizes and timing are visible.
- **SOCKS5 proxy**: Same problem -- SOCKS5 tunnels TLS, doesn't terminate it.
- **Modify cc-connect**: Tight coupling. Adding a `--dump-ws-frames` flag requires cc-connect release cycle. Proxy is independent and adds replay capability.
- **eBPF/sockmap**: At ~540 frames/day, this is a sledgehammer for a nut.

**Decision rationale**: The proxy provides value for debugging (< 5% of sessions) but is unnecessary for routine observability. Deploy it as a subprocess inside the cc-connect container when needed, remove when not.

#### Prometheus Metrics: Per-Service Exporters

**Chosen**: Each data service (PG, Redis, Kafka, ClickHouse) gets a Prometheus exporter sidecar or uses its native `/metrics` endpoint. A collector scrapes these on a 15-second interval and forwards to central storage.

**Why not alternatives**:
- **No metrics**: Invisible resource trends. Without metrics, the first sign of trouble is a crash.
- **In-agent metrics only**: Vector's `internal_metrics` are useful but don't replace service-level metrics (query latency, cache hit rate, consumer lag).

**Current status**: Exporters for PG (`prometheuscommunity/postgres-exporter`), Redis (`oliver006/redis_exporter`), and Kafka (`danielqsj/kafka-exporter`) are designed but not yet deployed. ClickHouse exposes `/metrics` natively. Node exporter runs per host.

---

## 3. Layer 2: Collection & Routing

### 3.1 Decision Matrix

| Agent | Central Cluster (Mac/Orbstack) | Remote Clusters (Aliyun, Office) |
|---|---|---|
| **Grafana Alloy** | Primary target (unified) | Primary target (unified) |
| **Vector + OTel Collector** | Fallback / interim | N/A |
| **Fluentd** | N/A | Fallback if Alloy is too heavy |

### 3.2 Recommended: Grafana Alloy (Unified Collector)

**Chosen**: Alloy handles all three telemetry pillars (metrics, logs, traces) in a single binary (~50 MB, ~30-50 MB RAM idle). It:
- Scrapes Prometheus exporter endpoints (discovery via Docker labels)
- Reads container logs via Docker socket (or file tail)
- Receives OTLP traces from cc-connect and patrol
- Forwards to Redpanda (Kafka topic) for buffering and ClickHouse ingestion

**Why Alloy over Vector + OTel Collector (3 agents vs 1)**:

| Factor | Alloy | Vector + OTel Collector + Prometheus |
|---|---|---|
| Memory | 30-50 MB | 100-150 MB (combined) |
| Config format | River (hierarchical) | TOML + YAML + YAML |
| Metrics scraping | Built-in (Prometheus receiver) | Vector cannot scrape; need separate Prometheus |
| Trace collection | Built-in (OTLP receiver) | Need separate OTel Collector |
| Log parsing | Built-in (Loki receiver, filelog) | Vector does this well |
| Docker discovery | `discovery.docker` | Vector has `docker_logs` source |
| Single SIGHUP reload | Yes | Config-dependent per agent |

**Why Alloy over Fluentd**:
- Fluentd's memory footprint (80-200 MB) is larger than Alloy's.
- Fluentd's ClickHouse sink is a community gem (`fluent-plugin-clickhouse`), not officially maintained.
- Alloy is built by Grafana Labs, the same company behind our query layer.

### 3.3 Interim: Vector + OTel Collector

Until Alloy is validated, the existing Vector pipeline for cc-connect logs continues to work. OTel Collector runs alongside it for traces. This is safe: both agents can dual-write, and migration is per-table.

### 3.4 Remote Clusters: Fluentd Fallback

On Aliyun (sim, 2 GB RAM), Alloy's 30-50 MB footprint is competing with other services. Fluentd (40-80 MB) is comparable. The decision depends on whether remote clusters need:
- **Log shipping only**: Fluentd (simpler, battle-tested forward protocol over Tailscale)
- **Full metrics + traces**: Alloy (unified, fewer moving parts)

For the initial deployment, remote clusters keep their ad-hoc heartbeat curls. Shipping logs from remote infra containers (PG, Redis) is Phase 2.

---

## 4. Layer 3: Transport & Buffer

### 4.1 Decision Matrix

| Concern | Chosen Solution | Rejected Alternatives |
|---|---|---|
| Message bus | Redpanda (single binary, Kafka API) | Apache Kafka (JVM, heavy), NATS (no Kafka compatibility) |
| Retention | 7 days per topic | 1 day (too short for replay), 30 days (wasteful at 500 KB/day) |
| Producer protocol | Kafka JSON (envelope schema) | Protobuf/Avro (overhead for our volume) |
| Consumer protocol | ClickHouse Kafka Engine | Vector Kafka sink (extra hop), custom consumer (redundant) |

### 4.2 Justification

**Chosen: Redpanda** (`docker.redpanda.com/redpandadata/redpanda:latest`, `--mode dev-container`).

**Why Redpanda over Apache Kafka**:
- Single binary, no JVM. Starts in ~2 seconds vs 15-30 seconds.
- At our volume (< 900 events/day, < 500 KB/day), Kafka's tuning parameters are pure overhead.
- Kafka API compatible: any Kafka client library works unchanged.
- Redpanda's `--mode dev-container` optimizes for single-node, no-Raft deployments.

**Why Kafka at all** (given Vector directly writes to CK today):
- **CK downtime resilience**: If CK is unreachable, events accumulate in Kafka (up to 7 days). Currently, Vector drops them.
- **Replay**: Want to backfill a table? Replay from Kafka offset 0.
- **Multiple consumers**: Multiple CK tables can consume the same topic without affecting each other. Future consumers (e.g., a real-time alert processor) can join independently.
- **Decoupling**: Producers don't need to know table schemas. They just write to a topic.

**Why not skip Kafka**:
The alternative -- Vector writing directly to CK -- is simpler and works for today's volume. But every producer (cc-connect, patrol, boss, docker-event-watcher, future MCP) would need its own ingestion path. Kafka provides a single ingestion point. The cost (one container, ~256 MB RAM, negligible CPU) is worth the architectural cleanliness.

### 4.3 Topic Layout

| Topic | Partitions | Retention | Producers | Consumers |
|---|---|---|---|---|
| `cc.events` | 3 | 7 days | Vector/Alloy (cc-connect logs) | CK Kafka Engine -> `cc.message_log` |
| `patrol.events` | 1 | 7 days | Patrol agents (kcat / ruby-kafka) | CK Kafka Engine -> `patrol.event_log` |
| `otel.spans` | 1 | 7 days | OTel Collector (kafkaexporter) | CK Kafka Engine -> `otel.span_log` |
| `docker.events` | 1 | 3 days | docker-event-watcher | CK Kafka Engine -> `infra.docker_events` |
| `system.events` | 1 | 3 days | Future producers | CK Kafka Engine -> `infra.system_log` |

### 4.4 Envelope Schema (Shared Across All Topics)

Every Kafka message uses the same envelope:

```json
{
  "schema_version": "1.0",
  "source": "cc-connect | patrol | docker-events | system",
  "event_type": "message_received | turn_complete | heartbeat | anomaly | container:die | ...",
  "event_time": "2026-05-23T16:38:00.604Z",
  "producer": {
    "host": "infra-boss",
    "instance": "kyb-infra-cc-connect",
    "cluster": "mac-orbstack"
  },
  "payload": {
    "...": "..."
  }
}
```

**Why a shared envelope**:
- Consumers route by `source` + `event_type` without parsing payload.
- Cross-event correlation: query "all events from any source in a 5-minute window" by indexing `event_time`.
- `schema_version` enables format migrations.

---

## 5. Layer 4: Storage & Query

### 5.1 Decision Matrix

| Concern | Chosen Solution | Rejected Alternatives |
|---|---|---|
| Structured logs | ClickHouse MergeTree tables | Elasticsearch (heavy, slow ingest), PostgreSQL (row-oriented, slow for logs) |
| Traces | ClickHouse `otel.span_log` (via Kafka) | Grafana Tempo (extra backend, TraceQL instead of SQL), Jaeger (unmaintained) |
| Metrics | Prometheus -> ClickHouse (remote write) | Mimir/VictoriaMetrics (extra backends), InfluxDB (different query language) |
| Query Layer | Grafana (ClickHouse datasource) | Grafana (same; the datasource is the choice) |

### 5.2 Justification

#### Traces in ClickHouse, Not Tempo

This was the most contested decision (see `otel-kafka.md`). The argument for Tempo is "native TraceQL, better trace waterfall UI." The counterargument is:

| Factor | Traces in Tempo | Traces in ClickHouse |
|---|---|---|
| Storage backends | Tempo + CK = 2 | CK only = 1 |
| Query interface | TraceQL + SQL | SQL only |
| Logs-to-traces correlation | Tempo-CK derived fields | Same table, same query |
| Retention management | Tempo retention + CK TTL | Single CK TTL |
| Operational cost | 1 extra container, configure, monitor | 0 extra |
| Replay capability | None | Kafka retention enables replay |

At our volume (< 1000 spans/day), a dedicated trace backend is wasteful. ClickHouse's `otel.span_log` table stores spans as flat rows with indexed trace_id. Queries like "show all spans for trace_id X order by start_time" are single-table row scans -- fast even at 100x current volume. Grafana's ClickHouse datasource can display traces as a waterfall using a community plugin.

**Decision: traces in ClickHouse. Migrate to Tempo if and when any of these happen:**
1. Span volume exceeds 1M/day (unlikely < 2027)
2. Need TraceQL's advanced features (graphing, metrics from traces)
3. Grafana ClickHouse trace waterfall plugin proves inadequate

#### Prometheus Metrics -> ClickHouse Remote Write

Prometheus is the best tool for short-term (15d) alerting and ad-hoc metric queries on a single cluster. For long-term storage and multi-cluster views, metrics are remote-written to ClickHouse using the Prometheus remote write protocol. ClickHouse stores them as flat time-series tables.

**Why not keep metrics only in Prometheus**:
- Prometheus's local storage is ephemeral (pod/container dies = data loss)
- Multi-cluster queries require either global view (Mimir) or remote write
- Adding Mimir/VictoriaMetrics is another backend. ClickHouse is already running.

### 5.3 Table Layout

| Table | Database | Source | TTL | Size/90d |
|---|---|---|---|---|
| `message_log` | `cc` | cc-connect events via Kafka | 90 days | ~40 MB |
| `event_log` | `patrol` | Patrol events via Kafka | 90 days | ~38 MB |
| `span_log` | `otel` | OTel traces via Kafka | 30 days | ~10 MB |
| `docker_events` | `infra` | Docker events via Kafka | 90 days | < 1 MB |
| `claude_hook_events` | `kyb` | Boss emit-ck.sh (direct HTTP) | 30 days | ~5 MB |
| `boss_heartbeats` | `kyb` | Boss shell loop (direct HTTP) | 90 days | ~3 MB |
| `agent_log` | `boss` | Boss stdout via Kafka | 7 days | ~50 MB |

Total storage estimate: ~150 MB / 90 days across all tables. Fits comfortably on any cluster's disk.

### 5.4 Grafana Datasources

| Datasource | Type | URL | Tables |
|---|---|---|---|
| ClickHouse | ClickHouse plugin | `http://host.orb.internal:8123` | All tables above |
| Prometheus | Prometheus | `http://prometheus:9090` | Short-term alerts, single-cluster views |

Dashboards reference the ClickHouse datasource for all multi-cluster panels and long-range queries. Prometheus is used only for real-time alerting rules.

---

## 6. Data Flow Diagram

```
                                kyb CLUSTER (one per site)
  ┌────────────────────────────────────────────────────────────────────────────────┐
  │                                                                                │
  │  ┌──────────────────┐   ┌──────────────────┐   ┌────────────────────────┐      │
  │  │  cc-connect       │   │  patrol (×3)     │   │  infra containers      │      │
  │  │  (Go)             │   │  (Ruby)           │   │  (PG, Redis, Kafka,   │      │
  │  │                   │   │                   │   │   ClickHouse, Grafana, │      │
  │  │  logs → stdout    │   │  logs → stdout    │   │   sing-box, registry) │      │
  │  │  OTel SDK → OTLP  │   │  OTel SDK → OTLP  │   │                        │      │
  │  └────────┬─────────┘   └────────┬──────────┘   └───────────┬────────────┘      │
  │           │                      │                           │                   │
  │           ▼                      ▼                           ▼                   │
  │  ┌────────────────────────────────────────────────────────────────────────┐     │
  │  │                  GRAFANA ALLOY (one per cluster)                      │     │
  │  │                                                                       │     │
  │  │  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐  ┌──────────┐   │     │
  │  │  │ docker_logs │  │ OTEL        │  │ prometheus   │  │ discovery│   │     │
  │  │  │ source      │  │ receiver    │  │ scrape       │  │ .docker  │   │     │
  │  │  └──────┬──────┘  └──────┬──────┘  └──────┬───────┘  └──────────┘   │     │
  │  │         │                │                │                          │     │
  │  │         ▼                ▼                ▼                          │     │
  │  │  ┌─────────────────────────────────────────────────────┐             │     │
  │  │  │  VRL transforms / parse / enrich / route            │             │     │
  │  │  │  - parse_go_kv  (cc-connect slog key=value)         │             │     │
  │  │  │  - parse_json   (boss hook events, sing-box)        │             │     │
  │  │  │  - parse_patrol (key=value patrol output)           │             │     │
  │  │  │  - add_cluster_metadata                             │             │     │
  │  │  │  - route_by_service                                 │             │     │
  │  │  └──────────────────────────┬──────────────────────────┘             │     │
  │  └─────────────────────────────┼────────────────────────────────────────┘     │
  │                                │                                              │
  │                                ▼                                              │
  │  ┌──────────────────────────────────────────────────────────────────────┐     │
  │  │        REDPANDA (Kafka API, single node per cluster)                 │     │
  │  │                                                                      │     │
  │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────┐     │     │
  │  │  │cc.events │  │patrol.   │  │otel.     │  │infra.docker      │     │     │
  │  │  │          │  │events    │  │spans     │  │ .events          │     │     │
  │  │  │partition │  │partition │  │partition │  │partition         │     │     │
  │  │  │: 3       │  │: 1       │  │: 1       │  │: 1               │     │     │
  │  │  │ret: 7d   │  │ret: 7d   │  │ret: 7d   │  │ret: 3d           │     │     │
  │  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────┬──────────┘     │     │
  │  └───────┼─────────────┼─────────────┼────────────────┼────────────────┘     │
  └──────────┼─────────────┼─────────────┼────────────────┼──────────────────────┘
             │             │             │                │
             │             │             │                │
             ▼             ▼             ▼                ▼
      ┌───────────────────────────────────────────────────────────┐
      │              ClickHouse (central, Mac/Orbstack)           │
      │                                                           │
      │  Kafka Engine tables consume topics, Materialized Views   │
      │  write to MergeTree tables:                               │
      │                                                           │
      │  cc.kafka_queue ──► cc.message_log                        │
      │  patrol.kafka_queue ──► patrol.event_log                  │
      │  otel.kafka_queue ──► otel.span_log                       │
      │  infra.kafka_queue ──► infra.docker_events                │
      │                                                           │
      │  Also receives direct HTTP writes:                        │
      │    - kyb.claude_hook_events  (from boss emit-ck.sh)       │
      │    - boss_heartbeats         (from boss shell loop)       │
      │    - Prometheus remote write (metrics from exporters)     │
      └──────────────────────────┬────────────────────────────────┘
                                 │
                                 ▼
      ┌───────────────────────────────────────────────────────────┐
      │              Grafana (Mac/Orbstack)                       │
      │                                                           │
      │  ClickHouse datasource → all dashboards:                  │
      │    - Infra Overview  - cc-connect Messages                │
      │    - Patrol Health   - Docker Events                      │
      │    - Trace Explorer  - Token Cost                         │
      │    - Vector/Alloy Health                                   │
      │                                                           │
      │  Prometheus datasource → single-cluster alert rules       │
      └───────────────────────────────────────────────────────────┘
```

### 6.1 Direct Writes (No Kafka, Low-Volume)

Two data sources bypass Kafka and write directly to ClickHouse HTTP:

- **Boss heartbeats**: Shell loop, 1 event/60s. At 3 clusters, this is 4,320 events/day. Direct POST is simpler and the data is replaceable.
- **Boss claude_hook_events**: emit-ck.sh, fires on each Claude tool call. At ~200 events/day, direct POST is fine.

Both are **idempotent** (cardinality keys ensure upsert semantics in ReplacingMergeTree) and **non-critical** (losing a heartbeat or hook event causes no harm). Kafka would add latency and complexity for zero benefit.

### 6.2 Kafka Bypass: Feishu Proxy Capture

The feishu-proxy (MITM WS proxy, optional) can write directly to ClickHouse via Vector/Alloy or to a file. It does not need Kafka -- its capture volume is ~108 KB/day and it's only deployed during debugging sessions. When active, it writes JSON lines to stdout, which Alloy picks up and routes to `cc.ws_frames` table.

---

## 7. Deployment Matrix per Cluster

### 7.1 Mac/Orbstack (Central, 32 GB RAM, 12+ services)

| Component | Deployment | Status |
|---|---|---|
| ClickHouse (central) | Existing container | Running |
| Grafana | Existing container | Running |
| Redpanda | `kyb-infra-redpanda` | Not yet deployed **P0** |
| Grafana Alloy | `kyb-infra-alloy` | Not yet deployed **P0** |
| OTel Collector | `kyb-infra-otel-collector` | Interim if Alloy not ready |
| feishu-proxy | Inside cc-connect container | Optional, on-demand |
| docker-event-watcher | Inside kyb-infra-boss | Not yet deployed **P1** |
| Prometheus exporters | Sidecars per data service | Not yet deployed **P1** |

### 7.2 Aliyun (Remote, 2 GB RAM, 5 services)

| Component | Deployment | Status |
|---|---|---|
| Heartbeat loop | Existing shell script | Running |
| Redpanda | `kyb-infra-redpanda` | Phase 2 |
| Fluentd (or Alloy) | Log shipping agent | Phase 2 |
| docker-event-watcher | Inside kyb-infra-boss | Phase 2 |

### 7.3 Office nuc8 (Remote, 8 GB RAM, 5 services)

Same as Aliyun. Resource ceiling is higher so Alloy is feasible. Evaluate after Mac/Orbstack stabilization.

---

## 8. Migration Path

### Phase 0: Foundation (Week 1) -- NOW

- [x] ClickHouse running on Mac/Orbstack (existing)
- [x] Grafana running on Mac/Orbstack (existing)
- [x] Vector parsing cc-connect logs to `cc.message_log` (existing)
- [x] Boss heartbeats via shell loop (existing)
- [x] Boss claude_hook_events via emit-ck.sh (existing)

### Phase 1: Buffer & Reliability (Week 1-2)

- [ ] Deploy Redpanda container (`kyb-infra-redpanda`)
- [ ] Create topics: `cc.events`, `patrol.events`, `otel.spans`, `docker.events`
- [ ] Add Kafka sink to Vector (dual-write: direct CK + Kafka)
- [ ] Create CK Kafka Engine tables + Materialized Views for each topic
- [ ] Verify row counts match between direct Vector and Kafka-sourced ingestion
- [ ] Remove Vector direct CK sink; Kafka becomes primary path
- [ ] Deploy docker-event-watcher inside kyb-infra-boss

### Phase 2: Unify Collection (Week 2-3)

- [ ] Deploy Grafana Alloy on Mac/Orbstack
- [ ] Configure Alloy: `docker_logs` source, Prometheus scrape, OTLP receive
- [ ] Migrate Vector configs to Alloy River syntax
- [ ] Remove Vector; Alloy becomes primary collector
- [ ] Deploy OTel Collector for traces (or test Alloy's OTLP receiver)
- [ ] Add OTel SDK to cc-connect (instrument key functions)

### Phase 3: Metrics & Tracing (Week 3-4)

- [ ] Deploy Prometheus exporters: PG, Redis, Kafka, ClickHouse, Node
- [ ] Configure Alloy to scrape all exporters
- [ ] Configure Prometheus remote write -> ClickHouse
- [ ] Verify traces land in `otel.span_log` via Kafka
- [ ] Add trace_id correlation to cc-connect logs (log attributes include trace_id)

### Phase 4: Remote Clusters (Week 4-5)

- [ ] Deploy Fluentd (or Alloy) on Aliyun
- [ ] Configure log shipping over Tailscale to central Kafka
- [ ] Deploy Fluentd (or Alloy) on Office
- [ ] Deploy docker-event-watcher on both remote bosses
- [ ] Verify multi-cluster queries in Grafana

### Phase 5: Grafana Dashboards (Ongoing)

- [ ] Infra Overview (ClickHouse datasource)
- [ ] cc-connect Messages (throughput, latency, tokens)
- [ ] Patrol Health (heartbeat timeline, anomaly count)
- [ ] Docker Events (crash loop detection, OOM watch)
- [ ] Trace Explorer (trace waterfall via ClickHouse datasource)
- [ ] Token Cost (input/output tokens per session, per day)

---

## 9. Appendix: Rejected Alternatives Summary

### Interception Layer

| Approach | Document | Rejection Reason |
|---|---|---|
| tcpdump for WS capture | `proxy-intercept.md` §12 Alt 2 | TLS encryption makes payload invisible |
| SOCKS5 proxy | `proxy-intercept.md` §12 Alt 5 | Tunnels TLS, does not terminate it |
| eBPF/sockmap | `proxy-intercept.md` §12 Alt 3 | Requires kernel 5.3+, fragile, overkill for ~540 frames/day |
| iptables TPROXY | `proxy-intercept.md` §12 Alt 4 | IP-based redirection fragile, needs NET_ADMIN |
| Modify cc-connect natively | `proxy-intercept.md` §12 Alt 1 | Tight coupling to cc-connect release cycle |
| cAdvisor for container metrics | (not documented) | Another container; Docker events simpler for lifecycle |
| Built-in healthchecks only | `docker-events.md` §Recommendations | Only cc-connect has HEALTHCHECK; need more |

### Collection Layer

| Approach | Document | Rejection Reason |
|---|---|---|
| Vector as sole collector | `sidecar-pattern.md` §9 | Cannot scrape Prometheus metrics or receive OTLP traces |
| Fluentd as sole collector | `fluentd-pipeline.md` §6 | Higher memory, community CK sink, weaker than Alloy for unified |
| Filebeat | `sidecar-pattern.md` §3.1 | No ClickHouse sink, limited transforms |
| Logstash | `sidecar-pattern.md` §3.1 | 300-600 MB RAM, JRuby, overkill |
| Per-service sidecar Vector | `sidecar-pattern.md` §9 | ~225 MB total for 15 sidecars vs ~50 MB for single Alloy |
| Docker log driver (fluentd/syslog) | `sidecar-pattern.md` §9.1 | Limited transform, global impact on failure |

### Transport Layer

| Approach | Document | Rejection Reason |
|---|---|---|
| Apache Kafka | `kafka-message-bus.md` §6.1 | JVM-based, ~500 MB image, slow start, overkill for < 1 MB/day |
| NATS | (not documented) | No Kafka API compatibility; would need different client libraries |
| No buffer (direct Vector -> CK) | Status quo | Data loss on CK downtime; no replay capability |
| Vector disk buffer only | `vector-pipeline.md` §8.2 | Single-consumer; adding Kafka consumers requires republishing |

### Storage Layer

| Approach | Document | Rejection Reason |
|---|---|---|
| Grafana Tempo for traces | `otel-kafka.md` §2 | Second storage backend; TraceQL vs SQL; extra operational cost |
| Jaeger for traces | `otel-kafka.md` §1 | Unmaintained (archived); no Grafana-native integration |
| Elasticsearch for logs | Common alternative | Heavy (1+ GB RAM), schema-on-write (painful), slow bulk ingest vs CK |
| Mimir for metrics | `sidecar-pattern.md` §3.4 | Extra backend; Prometheus remote write -> CK eliminates need |
| VictoriaMetrics for metrics | `sidecar-pattern.md` §3.4 | Same as Mimir; CK is already our long-term store |
| PostgreSQL for logs | Common alternative | Row-oriented; log queries scan too many rows; CK 100-1000x faster |

---

## 10. Cost-Benefit Summary

### What We Gain

| Capability | Before | After |
|---|---|---|
| Container lifecycle history | None (events invisible) | Full history in CK, Grafana dashboard, crash-loop alerts |
| Log persistence | Ephemeral (`docker logs` only) | 90-day retention in CK, queryable across clusters |
| Trace visibility | None | Full trace waterfall per message turn in Grafana |
| Multi-cluster metrics | Per-cluster silos | Unified Grafana views across Mac/Aliyun/Office |
| CK downtime resilience | Data loss | Kafka buffers up to 7 days |
| Debugging (WS replay) | None | Optional replay of any captured feishu session |

### Cost

| Resource | Value |
|---|---|
| New containers | Redpanda (1), Alloy (1), OTel Collector (interim, 1), Prometheus Exporters (3-5) |
| Additional RAM | ~400 MB total (Redpanda 256 MB + Alloy 50 MB + exporters ~100 MB) |
| Additional CPU | Negligible (< 0.2 core aggregate) |
| Additional disk | ~150 MB/90 days (logs + traces + events) |
| Maintenance | One more container to monitor (Redpanda); Alloy configuration in git |
| Risk | Kafka adds a failure mode; add-on to existing stack, not replacement |

The operational cost is **one additional container (Redpanda) and an agent swap (Vector -> Alloy)**. The exporters add 3-5 tiny sidecars (15-50 MB each). For a 32 GB host, this overhead is imperceptible.

---

> **Summary**: One unified collector (Alloy), one message bus (Redpanda), one storage engine (ClickHouse), one query layer (Grafana). The entire observability stack runs in ~500 MB RAM, ~150 MB/90d disk. Data flows from service -> Alloy -> Kafka -> CK -> Grafana in a straight line, with two legacy direct-HTTP paths for low-volume heartbeats. Implementation is 4-5 weeks phased, starting with the single most impactful change: Kafka buffering to eliminate data loss on CK downtime.

> ／人◕ ‿‿ ◕人＼
