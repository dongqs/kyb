---
decision: 稍微有点不确定等专家再审一轮
---

# OTel Observability for cc-connect

**Date**: 2026-05-23
**Scope**: Full OTel trace from Feishu WebSocket receive through cc-connect agent loop to Claude API and back out to Feishu. Span schema, attributes, context propagation, export pipeline.

---

## Background

cc-connect currently logs structured lines via Go `slog` (key=value format, not JSON) and debug lines via Go standard logger. These are consumed by Vector for ClickHouse ingestion (see `bridge-ck-ingestion.md` design). This provides basic metrics and message logging but lacks **distributed tracing** -- you cannot follow a single message turn across Feishu WS, cc-connect internal stages, Claude API calls, and tool execution.

OTel traces solve this: every message turn gets a trace, every processing stage gets a span, and every Claude API call gets a child span with token counts and latency. With OTel exported to Grafana Tempo (or Jaeger), operators can click into a slow message and see exactly which stage is the bottleneck.

## Target Architecture

```
Feishu WebSocket
    │
    ▼
┌─────────────────────────────┐
│       cc-connect            │
│  (Go, OTel-instrumented)    │
│                             │
│  trace-root at msg receive  │
│  child-spans for:           │
│   - route                   │
│   - agent loop              │
│   - Claude API call         │
│   - tool execution          │
│   - permission request      │
│   - Feishu send             │
└──────────┬──────────────────┘
           │ OTLP (gRPC/HTTP)
           ▼
┌─────────────────────────────┐
|    OTel Collector           │
|  (otel-collector container) │
|                             │
|  -> Tempo (traces)          │
|  -> Prometheus (metrics)    │
|  -> ClickHouse (logs+traces)│
└─────────────────────────────┘
```

### Components

| Component | Role |
|-----------|------|
| **cc-connect** | Go binary with manual OTel instrumentation: create spans, inject/read context, export via OTLP |
| **OTel Collector** | Lightweight gateway/agent container, receives OTLP, fan-out to backends |
| **Tempo / Jaeger** | Trace storage and query UI (choose Tempo for native OTLP + Grafana integration) |
| **Prometheus** | Metrics from OTel (span counts, latency histograms via OTel metrics SDK or Prometheus exporter) |
| **Grafana** | Unified dashboard: Tempo datasource for traces, Prometheus for metrics, ClickHouse for logs |

### Deployment note

OTel Collector runs as a sidecar or standalone container on the same host as cc-connect. gRPC OTLP export from cc-connect to collector over localhost (no auth, low latency). Collector handles retries, batching, and backpressure before forwarding to Tempo/Prometheus.

---

## Trace Model

### Root span: `feishu.message.receive`

Created when cc-connect picks up an event from the Feishu WebSocket connection. This span is the **trace root** -- its TraceID becomes the canonical identifier for the entire message turn.

**SpanKind**: `CONSUMER` (receiving from a message bus / WebSocket event)

**Attributes**:

| Attribute | Type | Value | Source |
|-----------|------|-------|--------|
| `feishu.msg_id` | string | `om_abc123` | Feishu event payload |
| `feishu.chat_id` | string | `oc_xxx` | Extracted from session |
| `feishu.sender_id` | string | `ou_xxx` | Feishu event |
| `feishu.chat_type` | string | `group` / `p2p` | Feishu event |
| `feishu.message_type` | string | `text` / `image` / `post` / `interactive` | Feishu event |
| `feishu.content_length` | int | 65 | len(content) |
| `feishu.has_images` | bool | false | Feishu event |
| `feishu.has_audio` | bool | false | Feishu event |
| `feishu.has_files` | bool | false | Feishu event |
| `messaging.system` | string | `feishu` | OTel semantic convention |
| `messaging.operation` | string | `receive` | OTel semantic convention |
| `messaging.message_id` | string | `om_abc123` | OTel semantic convention |

**Events** (structured log-like annotations on the span):

- `feishu.raw_event` -- the raw event payload (sampled, not always recorded; include at DEBUG level only to avoid PII overload)

---

### Span: `cc.message.route`

Internal routing: determining session, agent, handler for this message.

**SpanKind**: `INTERNAL`

**Parent**: `feishu.message.receive`

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `cc.session` | string | `feishu:oc_xxx:ou_xxx` |
| `cc.router` | string | `default` / `system` / `admin` |
| `cc.session_exists` | bool | true / false |

---

### Span: `cc.agent.process`

The main agent processing loop: one invocation of the agent that calls Claude and handles tool results, potentially over multiple turns. This span covers the entire agent think-act-observe cycle.

**SpanKind**: `INTERNAL`

**Parent**: `cc.message.route` (or `feishu.message.receive` if routing is trivial)

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `cc.agent_session` | string | UUID |
| `cc.session` | string | `feishu:oc_xxx:ou_xxx` |
| `cc.turn_count` | int | Number of tool-call cycles in this turn |
| `cc.error` | string | Error message if agent panicked (only on error spans) |

**Status**: `OK` if response was sent successfully; `ERROR` if agent crashed or timed out.

---

### Span: `claude.api.call`

Individual HTTP request to the Claude API (Anthropic Messages API). If the agent makes multiple API calls (e.g., retries, follow-up tool calls), each gets its own child span.

**SpanKind**: `CLIENT` (outbound HTTP call)

**Parent**: `cc.agent.process`

**Attributes**:

| Attribute | Type | Value | Source |
|-----------|------|-------|--------|
| `claude.request.model` | string | `claude-sonnet-4-20250514` | Request body |
| `claude.request.max_tokens` | int | 8192 | Request body |
| `claude.request.tool_count` | int | Number of tools configured | Request body |
| `claude.response.input_tokens` | int | 431 | Response usage |
| `claude.response.output_tokens` | int | 521 | Response usage |
| `claude.response.stop_reason` | string | `end_turn` / `tool_use` / `max_tokens` | Response |
| `claude.response.stop_sequence` | string | null | Response |
| `http.request.method` | string | `POST` | OTel semantic convention |
| `url.full` | string | `https://api.anthropic.com/v1/messages` | -- |
| `http.response.status_code` | int | 200 | HTTP status |
| `server.address` | string | `api.anthropic.com` | OTel semantic convention |

**Events**:

- `claude.request.body` -- first 1024 chars of request (sampled, sensitive content masked)
- `claude.response.body` -- first 1024 chars of response (sampled)

**Status**: `OK` if HTTP 200; `ERROR` if HTTP 4xx/5xx or network error.

---

### Span: `cc.tool.execute`

Executing a single tool call (e.g., Bash, read file, web fetch).

**SpanKind**: `INTERNAL`

**Parent**: `cc.agent.process` (sibling to `claude.api.call`)

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `cc.tool.name` | string | `Bash` / `Read` / `WebFetch` |
| `cc.tool.input_length` | int | Chars of tool input |
| `cc.tool.output_length` | int | Chars of tool output |
| `cc.tool.exit_code` | int | 0 (for Bash) |
| `cc.tool.duration_ms` | int | Wall-clock time of execution |

**Status**: `OK` if tool completed; `ERROR` if tool crashed or timed out (often tool-level errors are expected and not fatal).

---

### Span: `cc.permission.request` / `cc.permission.resolve`

Human-in-the-loop permission check. A permission requested, then later resolved (approved or denied) -- these are two separate spans linked by `request_id`.

**SpanKind**: `INTERNAL`

**Parent**: `cc.agent.process`

**Attributes (request)**:

| Attribute | Type | Value |
|-----------|------|-------|
| `cc.permission.request_id` | string | UUID |
| `cc.permission.tool` | string | `Bash` |
| `cc.permission.timeout_ms` | int | Timeout before auto-deny |

**Attributes (resolve)**:

| Attribute | Type | Value |
|-----------|------|-------|
| `cc.permission.request_id` | string | UUID |
| `cc.permission.decision` | string | `approved` / `denied` / `timeout` |
| `cc.permission.resolved_by` | string | `human` / `auto` |
| `cc.permission.duration_ms` | int | Time to resolution |

The **link** between request and resolve uses `cc.permission.request_id` as a join key. In Tempo you search for the request_id and see both spans.

---

### Span: `feishu.message.send`

Sending the final response (or intermediate message) back to Feishu.

**SpanKind**: `PRODUCER` (sending a message to a message bus / WebSocket)

**Parent**: `feishu.message.receive` (the root -- the send completes the turn)

**If there are multiple sends** (streaming, chunked): each chunk is a separate child span, or use span links.

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `feishu.msg_id` | string | `om_abc123` |
| `feishu.response_length` | int | 554 |
| `feishu.is_final` | bool | true / false |
| `messaging.system` | string | `feishu` |
| `messaging.operation` | string | `send` |
| `cc.agent_session` | string | UUID |

**Status**: `OK` if Feishu API confirmed delivery; `ERROR` if rate-limited or auth failure.

---

## Complete Trace DAG

A typical message turn produces this span tree:

```
feishu.message.receive                           (root, CONSUMER)
├── cc.message.route                             (INTERNAL)
├── cc.agent.process                             (INTERNAL)
│   ├── claude.api.call  #1                      (CLIENT)
│   ├── cc.permission.request                    (INTERNAL)
│   │   └── cc.permission.resolve                (INTERNAL)
│   ├── cc.tool.execute                          (INTERNAL)
│   └── claude.api.call  #2                      (CLIENT)
└── feishu.message.send                          (PRODUCER)
```

Total spans per turn: 4-8 (depends on number of Claude calls and tool executions).

---

## Context Propagation

### In-process (Go)

Trace context flows through Go `context.Context`. Every function that touches a message turn takes `ctx context.Context` as its first parameter:

```go
func handleMessage(ctx context.Context, event FeishuEvent) error {
    ctx, span := tracer.Start(ctx, "feishu.message.receive",
        trace.WithSpanKind(trace.SpanKindConsumer),
    )
    defer span.End()

    ctx = routeMessage(ctx, event)
    // ...
}
```

### Outbound to Claude API

OTel W3C Trace Context propagates via HTTP headers:

```
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
tracestate: cc=turn_count=2
```

- `traceparent` sent on every outbound HTTP request to `api.anthropic.com`
- The Claude API itself may not return trace context (it is a third-party service), but the span still captures the request/response timing and metadata
- If Anthropic ever supports trace context, `traceid` would be returned in response headers and could be linked

### Internal permission requests

Permission flow spans (request → resolve) are connected by `cc.permission.request_id`. When the human resolves via Feishu interaction, the resolve handler receives the request_id and creates a linked span with the same attribute for Tempo search.

---

## Export Pipeline

### OTel Collector config (minimal)

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
  memory_limiter:
    check_interval: 1s
    limit_mib: 512

exporters:
  otlp/tempo:
    endpoint: tempo.monitoring:4317
    tls:
      insecure: true
  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: cc_connect

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/tempo]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
```

### Exported metrics (from OTel SDK)

cc-connect should also use OTel metrics SDK (or Prometheus Go client) to export:

| Metric | Type | Attributes |
|--------|------|------------|
| `cc.messages.received` | Counter | `chat_type`, `message_type` |
| `cc.messages.sent` | Counter | `status` |
| `cc.claude.call_duration_ms` | Histogram | `model`, `status` |
| `cc.claude.tokens_total` | Counter | `direction` (input/output), `model` |
| `cc.tool.execution_duration_ms` | Histogram | `tool_name`, `status` |
| `cc.tool.calls_total` | Counter | `tool_name` |
| `cc.permission.duration_ms` | Histogram | `tool`, `decision` |
| `cc.turn_duration_ms` | Histogram | (none, or `has_tools`) |
| `cc.errors_total` | Counter | `stage`, `error_type` |

These feed Grafana dashboards (latency heatmaps, token spend trends, error rates).

---

## Sampling Strategy

### Volume estimate

At ~90 messages/day and ~6 spans/turn = ~540 spans/day. At this scale:

- **Sample all traces** (head-based, no sampling). The cost of storing every trace is negligible (~1 MB/day for traces alone).
- No need for tail-based sampling or rate limiting.
- If volume grows 100x, switch to **head-based probabilistic sampling** at 10-50% with a `Sampler` that prioritizes:
  1. Error spans (always sample)
  2. Slow spans (>P90 threshold, always sample)
  3. Random remainder

### PII concern

Feishu message content (actual user text) should NOT be stored in span attributes. Use span **events** (annotations) for content, and only when sampled at a low rate (e.g., 1% for debugging). The attributes focus on metadata (message_id, lengths, counts) that are PII-safe for observability.

---

## Grafana Integration

### Tempo datasource

Add Tempo as a Grafana datasource. Search by:

- `feishu.msg_id` -- find trace for a specific message
- `cc.session` -- all traces for a session
- `claude.response.input_tokens > 500` -- high-input-token traces
- Duration > 30s -- slow traces

### Trace-to-logs

Link Tempo traces to ClickHouse log records via `trace_id`. When viewing a trace, click "Related logs" to see the raw `cc.message_log` rows for that trace.

### Derive SLOs from traces

| SLO | Measure | Source |
|-----|---------|--------|
| E2E latency P50 < 10s | `feishu.message.receive` to `feishu.message.send` | Trace duration |
| Claude API P95 < 30s | `claude.api.call` span duration | Span duration |
| Token consumption / turn | Sum of `claude.response.{input,output}_tokens` per trace | Span attributes |
| Error rate < 1% | Spans with `status=ERROR` / total traces | Span status |
| Permission resolution P50 < 60s | `cc.permission.request` to `cc.permission.resolve` | Span-link duration |

---

## Instrumentation Plan

### Phase 1: Core spans (P0)

Instrument the critical path in cc-connect Go code:

1. OTel Go SDK init (OTLP exporter, resource detection)
2. `feishu.message.receive` -- at the WebSocket event handler entrypoint
3. `claude.api.call` -- wrap every HTTP call to `api.anthropic.com`
4. `feishu.message.send` -- at Feishu API call for response
5. `cc.agent.process` -- wrap the main `handleMessage` / agent loop function

### Phase 2: Detail spans (P1)

6. `cc.tool.execute` -- wrap each tool invocation
7. `cc.permission.request` / `cc.permission.resolve` -- permission flow
8. `cc.message.route` -- routing decision

### Phase 3: Metrics + dashboards (P1)

9. OTel metrics SDK counters and histograms
10. Grafana dashboards: trace search, latency heatmaps, token spend
11. Tempo / ClickHouse trace-to-logs linking

### Phase 4: Alerting (P2)

12. Derived alert rules: high error rate, no traces received (cc-connect down), permission timeouts

---

## Considerations

### Go OTel SDK maturity

The Go OTel SDK (`go.opentelemetry.io/otel`) is stable for traces (v1.x) and metrics (v1.x). Key packages:

- `go.opentelemetry.io/otel` -- API
- `go.opentelemetry.io/otel/sdk` -- SDK (trace provider, span processor)
- `go.opentelemetry.io/otel/exporters/otlp/otlptrace` -- OTLP trace exporter
- `go.opentelemetry.io/otel/exporters/otlp/otlpmetric` -- OTLP metric exporter (if using OTel metrics)
- `go.opentelemetry.io/otel/semconv/v1.26.0` -- semantic conventions

### Trace context in goroutines

cc-connect uses goroutines for concurrent message handling. The parent `context.Context` must be passed through to spawned goroutines explicitly. Use `context.WithCancel` / `context.WithTimeout` to ensure spans are properly ended even on panics or timeouts.

### Feishu WS reconnect

On WebSocket reconnect, the OTel tracer must not lose context. The tracer is stateless (spans are exported per-process), so reconnect only affects the `feishu.message.receive` span creation -- no tracer reconfiguration needed.

### Cost at scale

Estimated daily trace volume at today's usage:

| Item | Value |
|------|-------|
| Messages/day | ~90 |
| Spans/message | ~6 |
| Spans/day | ~540 |
| Span size (avg) | ~200 bytes (key+value) |
| Daily trace data | ~108 KB |
| Tempo retention (30d) | ~3.2 MB |

This is negligible. Even at 100x growth (~54K spans/day, ~10 MB/day), Tempo handles this easily with default configurations.

---

## References

- Existing observability design: `docs/infra/observability-design.md`
- Existing ClickHouse ingestion design: `docs/infra/designs/bridge-ck-ingestion.md`
- Review of above design: `docs/infra/reviews/review-bridge-ck-ingestion-A1.md`
- Go OTel SDK: https://opentelemetry.io/docs/languages/go/
- OTel semantic conventions: https://opentelemetry.io/docs/specs/semconv/
