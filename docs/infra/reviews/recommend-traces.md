---
decision: 稍后做
---

# Recommendation: Tracing Approach for kyb Infra

**Date:** 2026-05-23
**Status:** Single recommendation (synthesis of 5 prior trace designs)
**Scope:** Trace ingestion, storage, query, and cross-container correlation for all kyb infra services (cc-connect, patrol, boss, MCP, docker-event-watcher)

---

## Executive Summary

**Decision: OTel SDK -> OTel Collector -> Kafka -> ClickHouse. Do NOT deploy Tempo.**

Traces flow through the same Kafka bus as logs and events, landing in ClickHouse's `otel.span_log` table alongside all other observability data. Cross-container trace correlation uses W3C TraceContext (HTTP) for SDK-instrumented services and `correlation_id` (manual) for shell-based services.

This is the recommendation from `recommended-stack.md` (the single-source-of-truth synthesis of 50+ review documents). Five prior trace designs assumed Tempo; this recommendation overrides them.

---

## 1. The Three Options

| Criteria | Skip Tracing | OTel -> Tempo | OTel -> Kafka -> CK (Chosen) |
|----------|-------------|---------------|------------------------------|
| Storage backends | 1 (CK only) | 3 (CK + Tempo + Prometheus) | 2 (CK + Prometheus) |
| Trace waterfall | None | Built-in (Tempo) | Grafana CK plugin |
| TraceQL | None | Native | SQL only |
| Trace-to-logs correlation | N/A | Tempo-CK bridge or derived fields | Same table, native JOIN |
| Replay on schema change | N/A | None | Yes (Kafka retention) |
| CK downtime resilience | N/A | Spans dropped (OTel SDK default) | Kafka buffers up to 3 days |
| Cross-container traces | N/A | Single Tempo backend unifies by TraceID | Single CK table, same TraceID |
| Operational cost | Zero | Tempo container (~256 MB) + config | Reuses existing Kafka + CK |

### 1.1 Why Not Skip

Tracing is the only way to answer "what actually happened during this message turn?" Logs give you isolated events; traces give you the causal chain. At 540 spans/day, the cost is negligible and the debugging value is high. Without traces, latency breakdown (was it Claude API or SSH exec?), error attribution, and cross-container diagnostics are guesswork.

### 1.2 Why Not Tempo

This was the most contested decision in the review process. The argument for Tempo is legitimate -- TraceQL is powerful, the waterfall UI is mature, and service graph generation is built-in.

However, at kyb infra's current and projected scale:

- **540 spans/day** -- Tempo is designed for millions of spans/day. We are 4 orders of magnitude below its sweet spot.
- **2-3 services** (cc-connect, patrol, boss) -- Service graph has no value at this count.
- **SQL is sufficient** -- Every useful TraceQL query has a direct SQL equivalent: `{service.name="cc-connect" | status=error}` becomes `WHERE service_name = 'cc-connect' AND status_code = 'ERROR'`.
- **We already run Kafka + CK** -- The incremental cost of routing traces through the existing bus is near zero. Adding Tempo means a new container, new retention policy, new Grafana datasource, and a cross-backend bridging layer for trace-to-logs.
- **Replay matters** -- When span schema changes (it will), Kafka retention lets us re-ingest into a new table. Tempo has no replay.

Tempo decision is **deferred, not rejected**. If span volume exceeds 1M/day, or if Grafana's CK trace waterfall proves inadequate, add Tempo back as a Kafka consumer (not as a direct OTLP target).

### 1.3 Why CK via Kafka (Chosen)

The chosen approach is the simplest path to full observability:

```
Single ingestion bus (Kafka)
    -> Single storage backend (CK)
        -> Single query interface (Grafana + SQL)
```

Every other observability data type (logs, events, heartbeats) already follows this path. Traces join the same queue. The benefit is not just operational simplicity -- it enables native trace-to-logs correlation without bridging, replay on schema migration, and CK-downtime resilience.

---

## 2. Architecture

### 2.1 Data Flow

```
SDK-instrumented services:            Shell-based services:
  cc-connect (Go)                       patrol (shell/Ruby)
  MCP proxy (Go/Python)                 docker-event-watcher (shell)
  Boss (Ruby, future)                   boss-heartbeats (shell)
        |                                      |
        | OTLP gRPC/HTTP                       | JSON Lines file
        v                                      v
  OTel Collector (super-boss)           OTel Collector (filelog receiver)
        |                                      |
        | kafkaexporter                        | kafkaexporter
        v                                      v
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  Redpanda (Kafka API) -- topic: otel.spans
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        |
        | CK Kafka Engine consumer
        v
  ClickHouse -- table: otel.span_log
        |
        | Query: SQL (Grafana CK datasource)
        v
  Grafana -- Trace waterfall, dashboards, alerts
```

Remote clusters (Aliyun, Office):
  - docker-event-watcher + boss-heartbeats -> lightweight OTel Collector agent
  - Agent forwards OTLP to super-boss collector over Tailscale
  - Same pipeline from there

### 2.2 Components

| Component | Role | Status |
|-----------|------|--------|
| OTel SDK (Go) | Manual instrumentation in cc-connect, MCP proxy | To implement |
| OTel SDK (Ruby) | Future patrol/boss instrumentation | To implement |
| OTel Collector (super-boss) | OTLP receiver, batching, kafkaexporter | To deploy |
| OTel Collector agent (remote) | Filelog receiver, forward OTLP over Tailscale | To deploy |
| Redpanda (topic: `otel.spans`) | Buffering, replay, CK-downtime resilience | To create topic |
| ClickHouse (`otel.span_log`) | All span storage, query via Grafana CK datasource | To create table |
| Grafana (CK datasource) | Trace waterfall visualization, dashboards | Already configured |

### 2.3 Topic Design

```
Topic:    otel.spans
Partitions: 3 (keyed by trace_id hash -- preserves per-trace ordering)
Retention:  3 days
Format:     JSON (flat attribute map, not OTel protobuf array)
```

Message key = `trace_id` ensures all spans in a trace land in the same partition, preserving within-trace ordering for CK Kafka Engine consumption.

### 2.4 ClickHouse Schema

```sql
CREATE TABLE otel.span_log (
    event_time      DateTime64(9),
    trace_id        String,
    span_id         String,
    parent_span_id  String,
    name            LowCardinality(String),
    kind            UInt8,
    start_time      DateTime64(9),
    end_time        DateTime64(9),
    duration_ns     Int64,
    status_code     UInt8,
    status_message  String,
    service_name    LowCardinality(String),

    -- Common attributes (extracted for efficient filtering)
    infra_cluster       LowCardinality(String),
    infra_hostname      String,
    correlation_id      String,

    -- Raw JSON for forward compatibility
    attributes_json     String,
    events_json         String,
    resource_json       String
) ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (event_time, trace_id, start_time)
TTL event_time + INTERVAL 30 DAY;
```

This is a simplified schema vs. the one in `otel-kafka.md`. The key difference: fewer extracted columns initially. Extract only the attributes that are queried frequently (`infra_cluster`, `infra_hostname`, `correlation_id`). Everything else stays in `attributes_json` and is queried via `JSONExtractString` when needed. Add extracted columns as usage patterns emerge.

Add a bloom filter index on `trace_id` once volume exceeds 100K spans:

```sql
ALTER TABLE otel.span_log ADD INDEX trace_id_idx (trace_id) TYPE bloom_filter GRANULARITY 1;
```

---

## 3. Cross-Container Trace Correlation

### 3.1 Mechanism by Service Pair

| Services Involved | Correlation Method | Mechanism |
|-------------------|-------------------|-----------|
| cc-connect -> Claude API | W3C TraceContext | `traceparent` HTTP header |
| cc-connect -> boss (HTTP dispatch) | W3C TraceContext | `traceparent` HTTP header on `/api/dispatch` |
| patrol -> any (health check) | `correlation_id` attribute | Manual key passed in script |
| docker-event-watcher -> patrol | Time-window + container_name | SQL time-range JOIN |
| cc-connect <-> patrol | `correlation_id` attribute | Manual key in patrol alert |

### 3.2 SDK Services (cc-connect, boss, MCP proxy)

Full W3C TraceContext propagation. Both services export to the same OTel Collector, which writes to the same Kafka topic, which lands in the same CK table. A single `WHERE trace_id = ?` query returns all spans across both services, ordered by time. Grafana's CK datasource renders them as a single waterfall.

Span naming convention (from `unified-otel.md`):

```
<domain>.<component>.<action>
Example: cc.boss.dispatch, boss.command.exec, feishu.message.receive
```

### 3.3 Shell Services (patrol, docker-event-watcher, heartbeats)

Shell scripts cannot natively propagate W3C TraceContext. Instead, they use a manual `correlation_id` attribute:

```json
{
  "trace_id": "<uuid>",
  "span_id": "<uuid>",
  "correlation_id": "patrol-round-1234-cc-healthcheck",
  ...
}
```

In Grafana, correlate across services: `WHERE correlation_id = 'patrol-round-1234-cc-healthcheck'`.

### 3.4 Cross-Container Trace Query Example

```sql
-- All spans for a Feishu-initiated boss command
SELECT service_name, name, start_time, duration_ns, status_code
FROM otel.span_log
WHERE trace_id = '0af7651916cd43dd8448eb211c80319c'
ORDER BY start_time;
```

Result: spans from both cc-connect and boss, interleaved by time, linked by `parent_span_id`.

---

## 4. Migration Path

### Phase 1: Deploy OTel Collector + Kafka topic (P0)

| Task | Depends On |
|------|-----------|
| Deploy OTel Collector container on super-boss | None (new container) |
| Create `otel.spans` Kafka topic (3 partitions, 3d retention) | Redpanda deployment |
| Create `otel.span_log` table in CK with Kafka Engine + MV | CK access |

### Phase 2: Instrument cc-connect (P0)

| Task | Depends On |
|------|-----------|
| Add OTel Go SDK to cc-connect | Phase 1 |
| Instrument `feishu.message.receive` (root span) | Go SDK init |
| Instrument `claude.api.call` (HTTP child span) | Phase 1 |
| Instrument `feishu.message.send` (closing span) | Phase 1 |
| Verify spans appear in CK `otel.span_log` | Phase 1 |

### Phase 3: Instrument boss + patrol (P1)

| Task | Depends On |
|------|-----------|
| Add `/api/dispatch` endpoint to boss (if not existing) | None |
| Instrument boss HTTP handler with OTel | Phase 1 |
| Add W3C TraceContext extraction from incoming `traceparent` | Boss OTel init |
| Update patrol to write JSON Lines to OTel Collector filelog receiver | Phase 1 |

### Phase 4: Cross-container correlation (P1)

| Task | Depends On |
|------|-----------|
| Add `cc.boss.dispatch` span in cc-connect | Phase 2 |
| Inject `traceparent` on cc-connect -> boss HTTP calls | Phase 2 |
| Verify cross-container trace in Grafana waterfall | Phase 3 |
| Add `correlation_id` to patrol -> health-check flows | Phase 3 |

### Phase 5: Dashboards + cleanup (P2)

| Task | Depends On |
|------|-----------|
| Grafana trace search dashboard (trace_id input, waterfall) | Phase 4 |
| Grafana slow-trace dashboard (duration > 30s) | Phase 4 |
| Grafana cross-container trace dashboard | Phase 4 |
| Remove Tempo container (if any interim deployment) | Phase 4 |
| Update `cross-container-traces.md`, `otel-cc-connect.md`, `otel-patrol.md` to reference this recommendation | Phase 4 |

---

## 5. Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tempo vs ClickHouse | ClickHouse | Single backend; Kafka replay; SQL is sufficient at 540 spans/day |
| Tempo return trigger | 1M spans/day or CK waterfall inadequate | Deferred, not rejected |
| Kafka vs direct OTLP | Kafka | CK-downtime resilience; replay; unified ingestion bus with logs |
| JSON vs Avro in Kafka | JSON | 800 bytes/span at 540/day = 430 KB/day. Not worth schema registry complexity |
| Attribute extraction | Extract only `infra_cluster`, `infra_hostname`, `correlation_id` | Minimize MV maintenance; use `JSONExtractString` for ad-hoc queries |
| Cross-container correlation: SDK services | W3C TraceContext | Standard OTel propagation; works natively across HTTP calls |
| Cross-container correlation: shell services | `correlation_id` attribute | Shell cannot do W3C; manual key is pragmatic until migration to SDK |

---

## 6. Prior Documents Overridden

This recommendation supersedes the Tempo-based pipelines in:

| Document | What Changes |
|----------|-------------|
| `otel-cc-connect.md` | OTLP exporter targets OTel Collector (not Tempo directly). Collector exports to Kafka (not Tempo). |
| `cross-container-traces.md` | Both cc-connect and boss export to same OTel Collector -> Kafka -> CK. Trace waterfall via Grafana CK plugin, not Tempo. |
| `unified-otel.md` | OTel Collector pipeline uses kafkaexporter instead of otlp/tempo. CK is primary storage. |
| `otel-mcp.md` | MCP proxy traces follow same Kafka -> CK pipeline. |
| `otel-patrol.md` | Patrol filelog receiver output goes to Kafka -> CK, not to Tempo. |

Documents that already align:

| Document | Status |
|----------|--------|
| `recommended-stack.md` | Already recommends CK over Tempo (this doc is consistent) |
| `otel-kafka.md` | Proposes the OTel -> Kafka -> CK pipeline (this doc adopts it) |

---

## References

- `docs/infra/reviews/recommended-stack.md` -- Synthesis decision: "Traces in ClickHouse, Not Tempo"
- `docs/infra/reviews/otel-kafka.md` -- Full design: OTel -> Kafka -> CK pipeline
- `docs/infra/reviews/unified-otel.md` -- Unified collector design (update pipeline to kafkaexporter)
- `docs/infra/reviews/cross-container-traces.md` -- Cross-container trace model (update storage to CK)
- `docs/infra/reviews/otel-cc-connect.md` -- cc-connect span definitions (reuse unchanged)
- `docs/infra/reviews/otel-mcp.md` -- MCP span definitions (reuse unchanged)
- `docs/infra/reviews/otel-patrol.md` -- Patrol span definitions (reuse unchanged)
- `docs/infra/reviews/kafka-message-bus.md` -- Kafka bus infrastructure (already deployed)

---

/人◕ ‿‿ ◕人＼
