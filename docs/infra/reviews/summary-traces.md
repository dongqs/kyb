---
decision: 现在就做
---

# Summary: Traces / OTel Dimension Across Reviews

**Date**: 2026-05-23
**Scope**: All `docs/infra/reviews/*.md` files analyzed for distributed tracing and OpenTelemetry (OTel) design, gaps, and recommendations.

---

## Table of Contents

1. [Systems with Tracing Designs](#1-systems-with-tracing-designs)
2. [Pipeline / Infrastructure Designs](#2-pipeline--infrastructure-designs)
3. [Trace-Unaware Systems (Gaps)](#3-trace-unaware-systems-gaps)
4. [Cross-Cutting Gaps](#4-cross-cutting-gaps)
5. [Recommendations](#5-recommendations)
6. [Design Proliferation Warning](#6-design-proliferation-warning)

---

## 1. Systems with Tracing Designs

### 1.1 cc-connect -- Feishu WebSocket Bridge

| Aspect | Detail |
|--------|--------|
| **Document** | `otel-cc-connect.md` |
| **Language** | Go |
| **Status** | Design proposal (not implemented) |
| **Exporter** | OTLP gRPC to OTel Collector |
| **Context propagation** | W3C TraceContext via HTTP headers to Claude API |
| **Span model** | 8 span types: `feishu.message.receive` (root), `cc.message.route`, `cc.agent.process`, `claude.api.call`, `cc.tool.execute`, `cc.permission.request`, `cc.permission.resolve`, `feishu.message.send` |
| **Sampling** | 100% at current volume (~540 spans/day) |
| **Backend** | Tempo (primary), Prometheus (metrics), ClickHouse via linking |
| **Maturity** | Detailed span schema, attributes, events. Phase 1-4 implementation plan. OTel Go SDK well-defined. |
| **Key decision** | Trace root at message receive, spans for each processing stage |

### 1.2 Patrol -- 5-Minute Patrol System

| Aspect | Detail |
|--------|--------|
| **Document** | `otel-patrol.md` |
| **Language** | Shell / Ruby |
| **Status** | Draft design proposal |
| **Exporter** | OTLP File Exporter (JSON Lines to file, Vector picks up) |
| **Context propagation** | File-based: trace_id written to /tmp/otel-traces.jsonl, passed as env var to sub-steps |
| **Span model** | 5 span types: `patrol.round` (root), `patrol.dispatch`, `patrol.check` (with 4 sub-spans: docker, disk, network, health), `patrol.heartbeat`, `patrol.report` |
| **Sampling** | 100% (288 rounds/day, low volume) |
| **Backend** | ClickHouse via Vector (file source -> otlp transform -> CK) |
| **Maturity** | Coarse-grained due to shell limitations. Known issues with file exporter context association, timestamp precision, export latency. |
| **Key decision** | File-based trace context is a pragmatic compromise for shell scripts |

### 1.3 MCP Proxy -- Model Context Protocol

| Aspect | Detail |
|--------|--------|
| **Document** | `otel-mcp.md` |
| **Language** | Any (proxy recommended: Go, Python, Node) |
| **Status** | Design proposal |
| **Exporter** | OTLP gRPC to OTel Collector |
| **Context propagation** | W3C TraceContext via JSON-RPC `_traceparent` field (stdio) or HTTP headers (SSE) |
| **Span model** | 7 span types: `mcp.request` (root), `mcp.transport.send`, `mcp.transport.receive`, `mcp.server.dispatch`, `mcp.tool.execute`, `mcp.tool.subcall`, `mcp.server.response` |
| **Sampling** | 10% head + 100% tail for error/latency |
| **Backend** | ClickHouse (`infra.otel_spans`), Tempo optional |
| **Maturity** | Proxy sidecar architecture well-defined. MCP proxy implementation not built. Relies on shared `request_id` across metrics, logs, and traces. |
| **Key decision** | MCP proxy sidecar preferred over per-server instrumentation (no code changes needed) |

### 1.4 Feishu WebSocket Proxy (otel-proxy)

| Aspect | Detail |
|--------|--------|
| **Document** | `otel-proxy.md` |
| **Language** | Go |
| **Status** | Design proposal |
| **Exporter** | OTLP gRPC to OTel Collector (dual export with stdout JSON) |
| **Context propagation** | Connection-level trace root; no context propagated to cc-connect (bridge via `msg_id` join) |
| **Span model** | 5 span types: `feishu.ws.connection` (root), `feishu.ws.upstream_connect`, `feishu.ws.frame_received`, `feishu.ws.frame_forwarded`, `feishu.ws.connection_close`. Optional message-level sub-traces. |
| **Sampling** | 100% at current volume (~540 frames/day). Hourly trace splitting for long-lived connections. |
| **Backend** | Tempo (primary), Prometheus (metrics), ClickHouse (from stdout fallback) |
| **Maturity** | Drop-in replacement for `feishu-proxy`. Phase 1-4 implementation plan. Performance impact negligible (~3 us per frame). |
| **Key decision** | Proxy creates traces independently; not linked to cc-connect's OTel traces (join by msg_id) |

### 1.5 Cross-Container Traces

| Aspect | Detail |
|--------|--------|
| **Document** | `cross-container-traces.md` |
| **Language** | Go (both sides) |
| **Status** | Design proposal |
| **Exporter** | Both containers export to the same OTel Collector |
| **Context propagation** | W3C TraceContext via HTTP `traceparent` header across container boundary |
| **Span model** | Extends `otel-cc-connect.md` with 5 new spans: `cc.boss.dispatch`, `cc.boss.result`, `boss.request.receive`, `boss.command.parse`, `boss.command.exec`, `boss.ssh.exec`, `boss.response.send` |
| **Sampling** | 100% for cross-container traces (~9/day, low volume) |
| **Backend** | Tempo, ClickHouse (`infra.otel_spans`) |
| **Maturity** | Detailed span schema, attribute definitions, context propagation code examples. Phase 1-4 implementation plan. Requires boss HTTP API. |
| **Key decision** | Boss API `/api/dispatch` must propagate traceparent from request header to child spans |

### 1.6 Claude Telemetry (tengu events)

| Aspect | Detail |
|--------|--------|
| **Document** | `claude-telemetry.md` |
| **Language** | Shell / Python (tengu-emit adapter) |
| **Status** | Design proposal |
| **Exporter** | Vector (file source -> CK sinks); NOT OTel-based |
| **Context propagation** | session_id as correlation key; no W3C TraceContext |
| **Event model** | 3 event types: `tengu_tool_use`, `tengu_session`, `tengu_error`. Each with common envelope (version, event_id, session_id, trace_id). |
| **Sampling** | 100% |
| **Backend** | ClickHouse (3 raw tables + 3 materialized views) |
| **Maturity** | Well-defined schema, materialized views, Grafana dashboards, alerting rules, pricing model for cost estimation. |
| **Key decision** | Uses custom tengu event format instead of OTel. Includes `trace_id` and `span_id` in envelope for future OTel integration. |

---

## 2. Pipeline / Infrastructure Designs

### 2.1 OTel Sidecar Pattern

| Aspect | Detail |
|--------|--------|
| **Document** | `otel-sidecar.md` |
| **Scope** | Per-container OTel Collector sidecar for every infra service |
| **Status** | Design proposal |
| **Key decision** | Per-container over per-host OTel Collector for isolation |
| **Export targets** | Tempo (primary), ClickHouse (archive), Prometheus (via SpanMetrics connector) |
| **Per-service config** | Independent sampling: patrol = 100%, cc-connect = 50%, PG/Redis/Kafka = 100% (low volume) |
| **Maturity** | Detailed docker-compose configs, docker run commands, batch attach script, lifecycle management, upgrade procedure. |
| **Conflict with other docs** | `otel-sidecar.md` advocates per-container collectors; `unified-otel.md` advocates a single collector. |

### 2.2 OTel + Kafka + Vector

| Aspect | Detail |
|--------|--------|
| **Document** | `otel-kafka-vector.md` |
| **Scope** | Full pipeline: OTel Collector -> Kafka -> Vector -> ClickHouse |
| **Status** | Design proposal |
| **Rationale** | Durable buffering, replay capability, backpressure isolation |
| **Kafka topics** | `otlp.traces` (3 partitions, 7d), `otlp.metrics` (2p, 14d), `otlp.logs` (2p, 7d) |
| **Format** | OTLP Protobuf in Kafka, decoded by Vector or stored raw in ClickHouse |
| **Maturity** | Detailed op playbook, volume estimates, redundancy matrix, migration path (Phase 0-4). |
| **Conflict with other docs** | This doc recommends Kafka as essential. `otel-vector.md` says Kafka is "extreme overkill" at current scale. |

### 2.3 OTel + Kafka (CK-native trace storage)

| Aspect | Detail |
|--------|--------|
| **Document** | `otel-kafka.md` |
| **Scope** | Replace Tempo with ClickHouse for trace storage, using Kafka as the transport |
| **Status** | Design proposal |
| **Key decision** | OTel spans -> Kafka (`otel.spans`) -> CK Kafka Engine -> MergeTree `otel.span_log`. Tempo optional during migration. |
| **CK trace view** | Grafana ClickHouse datasource supports trace waterfall view when columns match expected schema. |
| **Maturity** | CK trace tree reconstruction technique documented. Decision matrix comparing Tempo vs CK-native storage. |
| **Conflict with other docs** | Proposes removing Tempo entirely. `unified-otel.md` keeps Tempo. `otel-cc-connect.md` assumes Tempo. |

### 2.4 OTel + Vector Combined

| Aspect | Detail |
|--------|--------|
| **Document** | `otel-vector.md` |
| **Scope** | Two-stage: OTel Collector (protocol gateway) -> Vector (enrichment/routing) -> CK |
| **Status** | Design proposal |
| **Key decision** | OTel Collector handles OTLP term; Vector handles all transform/routing. Three CK tables: `otel_spans`, `otel_metrics`, `otel_logs`. |
| **Enrichment** | VRL transforms add cluster, environment, host, container_id to all signals. |
| **Maturity** | Full TOML config for Vector, YAML config for Collector, CK schemas, Grafana queries, migration plan. |
| **Conflict with other docs** | Directly contradicts `otel-kafka.md` on Kafka necessity. Says Kafka is "extreme overkill" at current volume. |

### 2.5 Unified OTel Architecture

| Aspect | Detail |
|--------|--------|
| **Document** | `unified-otel.md` |
| **Scope** | Consolidates 5 independent OTel designs into a single pipeline |
| **Status** | Design document |
| **Key decisions** | Single collector on super-boss; filelog receiver for shell-based services; remote agents for clusters over Tailscale; correlation_id for cross-service traces |
| **Service identity** | Canonical names: `cc-connect`, `mcp-proxy`, `patrol`, `docker-event-watcher`, `boss-heartbeat`, `infra-container` |
| **Unified schema** | `infra.otel_spans` + `infra.otel_logs` tables. Common infra attributes on every span. Namespace convention per service. |
| **Maturity** | Most comprehensive. Maps all existing designs, defines deployment plan (6 phases), cost estimate, decision log. |
| **Conflict resolution** | Recommends single collector (rejecting per-container sidecar pattern), Tempo + CK (not CK-only), filelog receiver (not Vector for shell traces), correlation_id (not W3C for cross-service yet). |

---

## 3. Trace-Unaware Systems (Gaps)

These systems exist in the review corpus but have **no tracing design**:

| System | Doc | Traces Status | What Would Be Needed |
|--------|-----|--------------|---------------------|
| **Kafka Message Bus** | `kafka-message-bus.md` | No trace design | OTel instrumentation for Kafka producers/consumers (suggested but not designed) |
| **Docker Event Watcher** | `docker-events.md` | Log records only | Could emit OTel spans for container lifecycle events. Currently fire-and-forget HTTP POST to CK. |
| **Boss Heartbeats** | (mentioned in `unified-otel.md`) | Log records only | No spans -- heartbeats are observations, not request-scoped. Adequate as logs. |
| **Grafana Alloy** | `grafana-alloy.md` | No | Alloy is an OTel-compatible collector (alternative to OTel Collector). Not integrated into any trace pipeline design. |
| **Fluentd Pipeline** | `fluentd-pipeline.md` | No | Fluentd is log-focused. No OTel integration. |
| **cAdvisor Metrics** | `cadvisor-metrics.md` | No | cAdvisor exports Prometheus metrics, not traces. Acceptable, but no span correlation. |
| **Node Exporter** | `node-exporter.md` | No | System metrics only. No trace dimension expected. |
| **sing-box / Proxy** | `sing-box-metrics.md`, `proxy-intercept.md`, `proxy-kafka.md` | No | Proxy has a design (`otel-proxy.md`) that covers this gap. sing-box has no OTel instrumentation. |
| **Bridge / Hooks Pipelines** | `review-bridge-ck-ingestion-*.md`, `review-bridge-hooks-*.md`, `hooks-*.md` | No | Pure data ingestion, no trace context. Acceptable for ETL pipelines. |
| **All review-issue-automation-*.md** | E1-E3 | No | Issue automation unrelated to traces. Acceptable gap. |
| **All review-mcp-D*.md** | D1-D3 | Logging/metrics only | D3 covers logging; tracing is in separate `otel-mcp.md`. |

---

## 4. Cross-Cutting Gaps

### Gap 1: No Single Source of Truth for Pipeline Architecture

There are **5 competing pipeline architectures** documented:

| Pipeline | Collector | Transport | Backend | Doc |
|----------|-----------|-----------|---------|-----|
| A | Single collector | Direct to Tempo | Tempo + Prometheus | `otel-cc-connect.md` |
| B | Per-container sidecars | Direct to backends | Tempo + CK | `otel-sidecar.md` |
| C | Single collector | Kafka -> Vector | CK (no Tempo) | `otel-kafka.md` |
| D | Single collector | Kafka -> Vector | CK + Tempo | `otel-kafka-vector.md` |
| E | Single collector | Vector (no Kafka) | CK + Tempo | `otel-vector.md` |
| F | Single collector (super-boss) + remote agents | Direct + Tailscale forwarding | CK + Tempo | `unified-otel.md` |

**Problem**: These are not alternatives being evaluated -- they are all presented as designs, with overlapping and contradictory recommendations. A team member reading these docs cannot determine which pipeline to implement.

**Root cause**: Designs were written independently before unification. `unified-otel.md` attempts consolidation but does not explicitly declare which other docs are superseded.

### Gap 2: No Implemented Traces

**Every single OTel design is in "design proposal" or "draft" status. Not one is implemented.**

Status summary:

| Doc | Status | Implemented? |
|-----|--------|-------------|
| `otel-cc-connect.md` | Design proposal | No |
| `otel-patrol.md` | Draft | No |
| `otel-mcp.md` | Design proposal | No |
| `otel-proxy.md` | Design proposal | No |
| `otel-sidecar.md` | Design proposal | No |
| `otel-kafka.md` | Design proposal | No |
| `otel-kafka-vector.md` | Design proposal | No |
| `otel-vector.md` | Design proposal | No |
| `unified-otel.md` | Design document | No |
| `cross-container-traces.md` | Design proposal | No |
| `claude-telemetry.md` | Design proposal | No |

At current state, all distributed tracing observability is zero (nothing). The existing observability relies on:
- Structured logs (`slog` in Go, JSON lines to Vector)
- ClickHouse table ingestion (message logs, hook events, Docker events)
- No span-based tracing, no TraceID correlation, no waterfall views

### Gap 3: No Sampling Strategy Convergence

| Doc | Sampling Rate |
|-----|--------------|
| `otel-cc-connect.md` | 100% (at 540 spans/day) |
| `otel-patrol.md` | 100% |
| `otel-mcp.md` | 10% head + 100% tail for error |
| `otel-proxy.md` | 100% + hourly trace splitting |
| `otel-sidecar.md` | Per-service: cc-connect 50%, patrol 100%, infra 100% |
| `unified-otel.md` | Hybrid: 100% for low-volume, 10% for healthcheck events |

No consensus. `otel-sidecar.md` suggests 50% for cc-connect; other docs say 100%. This matters because sampling affects trace completeness for debugging.

### Gap 4: Tempo vs ClickHouse for Trace Storage

| Doc | Trace Backend | Rationale |
|-----|-------------|-----------|
| `otel-cc-connect.md` | Tempo (primary) | Native OTLP, Grafana integration |
| `otel-kafka.md` | ClickHouse only (no Tempo) | Eliminates separate backend, unified query, replay |
| `otel-kafka-vector.md` | Tempo + CK | Tempo for real-time, CK for archive |
| `otel-vector.md` | CK (via Vector) | No Tempo; CK serves all signals |
| `unified-otel.md` | Tempo + CK | Tempo for UI, CK for analytics |

**Recommendation from `otel-kafka.md` decision matrix**: At 540 spans/day, CK-native trace storage is adequate. Tempo's advanced features (TraceQL, service graph) provide marginal benefit at this volume. The operational cost of Tempo (~512 MB RAM) is significant. **CK-only is the pragmatic choice until span volume exceeds 1M/day.**

### Gap 5: No OTel for Infra Services

PostgreSQL, Redis, Kafka, ClickHouse, and Grafana themselves have no OTel instrumentation. `otel-sidecar.md` plans for future integration but provides no implementation. These services are black boxes in the trace model.

### Gap 6: No OTel for Boss Agent

The boss agent (shell/Claude-driven) has no OTel instrumentation. Cross-container traces (`cross-container-traces.md`) assume boss has OTel SDK instrumentation for HTTP API handling, but boss is a Claude agent running shell commands, not a Go binary. The boss HTTP API would need to be a separate service.

### Gap 7: Claude Telemetry is Not OTel

`claude-telemetry.md` defines custom `tengu_*` events that are NOT OTel spans. They include `trace_id` and `span_id` in the envelope for future integration, but currently have no OTel exporter, no context propagation, and no integration with the OTel Collector. This creates a parallel telemetry system.

### Gap 8: No Multi-Cluster Trace Correlation

`unified-otel.md` mentions remote cluster forwarding via Tailscale but provides no design for trace context propagation across cluster boundaries. W3C TraceContext could propagate over the Tailscale link if the remote collector agent injects `traceparent` into forwarded requests, but this is not specified.

### Gap 9: No Alerting on Traces

None of the OTel designs define concrete alerting rules based on traces. `claude-telemetry.md` defines alerts on tengu events (not traces). `otel-cc-connect.md` mentions SLOs from traces as a Phase 4 item (P2 priority). `unified-otel.md` defines alerting rules but they are based on Prometheus metrics, not traces directly.

---

## 5. Recommendations

### R1: Declare a Single Pipeline Architecture

**Pick one pipeline from Gap 1 and mark all others as superseded.**

Recommendation: Adopt **Option F (`unified-otel.md`)** with the following clarifications:

- **Single OTel Collector** on the super-boss (reject per-container sidecar from `otel-sidecar.md`)
- **Kafka is optional** and unnecessary at current volume (reject `otel-kafka.md` and `otel-kafka-vector.md`)
- **Vector is optional** for OTel traces; the OTel Collector's built-in exporters suffice. Vector is useful for enrichment and legacy pipeline convergence.
- **ClickHouse as primary trace store** with Tempo as optional UI (reject Tempo-only from `otel-cc-connect.md`)
- **filelog receiver** for shell-based services (patrol, docker events, heartbeats) as specified in `unified-otel.md`
- Mark ALL other pipeline docs (`otel-sidecar.md`, `otel-kafka.md`, `otel-kafka-vector.md`, `otel-vector.md`) as **superseded by unified-otel.md** with a header note at the top of each.

### R2: Implement Phase 1 Immediately

The highest-value, lowest-effort trace to implement is **cc-connect** (`otel-cc-connect.md`), because:
- Go OTel SDK is mature and stable
- cc-connect is the primary user-facing service
- Span model is well-defined
- Volume is negligible (~540 spans/day)

Do this before adding traces to any other service. It validates the pipeline end-to-end.

### R3: Resolve Sampling Contradiction

Agree on a single sampling strategy:
- **100% for all services** at current volume (< 10K spans/day)
- **Head-based probabilistic sampling** when volume exceeds 100K spans/day
- **Tail-based sampling for errors and latency** as a secondary layer at any volume
- Supersede the 50% cc-connect sampling from `otel-sidecar.md`

### R4: Plan Claude Telemetry -> OTel Migration

The tengu event schema in `claude-telemetry.md` should be migrated to OTel spans over time:
- `tengu_tool_use` -> OTel span with attributes
- `tengu_session` -> OTel span (root, `session.start` / `session.end`)
- `tengu_error` -> OTel span with ERROR status

The `tengu_version`, `event_id`, `trace_id`, `span_id` envelope fields already anticipate this migration.

### R5: Add Explicit Cross-Document Supersession Headers

Every doc in `docs/infra/reviews/` should have a header indicating its relationship to other docs:

```markdown
**Status**: Design proposal (SUPERSEDED BY unified-otel.md)
```

or:

```markdown
**Status**: Design proposal (COMPONENT OF unified-otel.md -- covers cc-connect span model only)
```

### R6: Define Alerting from Spans

Once traces are flowing, define concrete alerts:
- **No traces from service X for N minutes** -> P1 (service may be down)
- **Trace error rate > 5%** -> P1
- **Trace latency P99 > 30s** -> P2
- **Cross-container trace gap** (boss spans orphaned) -> P2

### R7: Add OTel to Boss HTTP API

Before implementing cross-container traces (`cross-container-traces.md`), ensure the boss API `/api/dispatch` endpoint has OTel SDK instrumentation. Without this, cross-container traces cannot work -- the boss side would produce orphaned spans.

---

## 6. Design Proliferation Warning

There are **11 documents** covering OTel/tracing in this directory, plus `claude-telemetry.md` as a parallel non-OTel telemetry design. This is excessive for a system with zero implemented traces.

Suggested consolidation:

| What to Keep | What to Archive/Supersede |
|-------------|--------------------------|
| `unified-otel.md` (master design) | `otel-sidecar.md` (superseded by unified-otel) |
| `otel-cc-connect.md` (span model reference) | `otel-kafka.md` (superseded by unified-otel) |
| `otel-patrol.md` (span model reference) | `otel-kafka-vector.md` (superseded by unified-otel) |
| `otel-mcp.md` (span model reference) | `otel-vector.md` (superseded by unified-otel) |
| `cross-container-traces.md` (span model reference) | |
| `claude-telemetry.md` (keep pending OTel migration) | |
| `otel-proxy.md` (keep if proxy is pursued) | |

Once the pipeline is implemented and stable, the span model reference docs (`otel-cc-connect.md`, `otel-patrol.md`, `otel-mcp.md`) can be merged into `unified-otel.md` and archived.

---

## Appendix: Complete Trace Design Matrix

| System | Language | Exporter | Context Propagation | Span Count | Sampling | Backend | Status |
|--------|----------|----------|--------------------|------------|----------|---------|--------|
| cc-connect | Go | OTLP gRPC | W3C TraceContext HTTP | 8 | 100% | Tempo + CK | Design |
| Patrol | Shell/Ruby | File -> Vector | File-based trace_id | 5+4sub | 100% | CK | Draft |
| MCP Proxy | Any | OTLP gRPC | W3C via JSON-RPC/HTTP | 7 | 10%+tail | CK+Tempo | Design |
| WS Proxy | Go | OTLP gRPC | Connection-level only | 5 | 100% | Tempo | Design |
| Cross-container | Go | OTLP gRPC | W3C TraceContext HTTP | 7 new | 100% | Tempo + CK | Design |
| Claude Telemetry | Shell/Python | Vector -> CK | session_id (not OTel) | 3 events | 100% | CK | Design |

---

*Generated by review of all `docs/infra/reviews/*.md` files.*
