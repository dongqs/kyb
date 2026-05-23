---
decision: 稍微有点不确定等专家再审一轮
---

# OTel-Enriched MITM Proxy for Feishu WebSocket

**Design doc**: `docs/infra/reviews/otel-proxy.md`
**Date**: 2026-05-23
**Scope**: Combine MITM WebSocket proxy (from `proxy-intercept.md`) with OTel instrumentation
(from `otel-cc-connect.md`) into a single binary that captures frames, enriches them with
OTel spans, and exports via OTLP. Eliminates the JSON-stdout-plus-Vector pipeline in favor
of native OTel export.

---

## 1. Motivation

Two existing designs cover complementary needs:

| Design | What It Does | What It Misses |
|--------|-------------|----------------|
| `proxy-intercept.md` | MITM proxy captures raw WS frames; dumps JSON lines to stdout; Vector ingests to ClickHouse | No trace context; no span hierarchy; frame-to-message correlation is manual (msg_id join) |
| `otel-cc-connect.md` | Full OTel trace from feishu receive through Claude API and back | Requires modifying cc-connect itself; frames are opaque; no raw WS visibility |

**This design merges both**: a MITM proxy that is itself an OTel instrumented service. Every
WebSocket frame becomes an OTel span. Frames are grouped into connection-level and
message-level traces. The proxy exports OTLP directly, bypassing the JSON-stdout pipeline
entirely (though stdout logging remains as a fallback).

**Key insight**: the proxy is in a unique position to observe both directions of every frame
with nanosecond timing. By making the proxy the OTel trace root, we get frame-level
observability **without touching cc-connect at all**.

---

## 2. Architecture

### 2.1 Overview

```
cc-connect container
    │
    │ WS (ws://127.0.0.1:9443)
    │ no TLS (loopback)
    ▼
┌─────────────────────────────────────────┐
│            otel-proxy                    │
│                                         │
│  ┌────────────┐   ┌──────────────────┐  │
│  │ WS Relay   │   │ OTel Engine      │  │
│  │ (forward   │   │                  │  │
│  │  frames    │   │ - Create spans   │  │
│  │  bidir)    │   │ - Set attributes │  │
│  └─────┬──────┘   │ - Manage trace   │  │
│        │          │   context        │  │
│        │          └────────┬─────────┘  │
│        │                   │            │
│        └───────────────────┘            │
│                                         │
│  ┌──────────────────────────────────┐   │
│  │ Binary Capture (optional)        │   │
│  │ --capture-dir /data/capture      │   │
│  └──────────────────────────────────┘   │
└──────────────────┬──────────────────────┘
                   │ WSS (wss://msg-frontier.feishu.cn:443)
                   │ TLS 1.3
                   ▼
              Feishu (msg-frontier.feishu.cn)
                   │
                   ▼
         OTel Collector (localhost:4317)
                   │
          ┌────────┼────────┐
          ▼        ▼        ▼
        Tempo   Prometheus  ClickHouse
       (traces) (metrics)  (logs via
                             OTel)
```

### 2.2 How It Differs from `proxy-intercept.md`

| Aspect | `proxy-intercept.md` | `otel-proxy.md` (this doc) |
|--------|---------------------|---------------------------|
| Capture format | JSON lines to stdout | OTel spans via OTLP |
| Storage pipeline | stdout → Vector → ClickHouse | OTLP → Collector → Tempo/ClickHouse |
| Trace context | None (msg_id join only) | Native OTel trace context |
| Frame-level latency | Ping/pong frames + timestamps | Span duration + OTel timing |
| Binary capture | Separate side-effect | Same binary, optional flag |
| Deployment | Standalone `feishu-proxy` binary | Replaces feishu-proxy; superset of its features |

### 2.3 Deployment

The proxy ships as a single Go binary named `otel-proxy`. It replaces `feishu-proxy`
entirely — same CLI interface, same port, same fail-open behavior. The only addition is
the OTLP exporter.

```bash
# Start (replaces feishu-proxy)
otel-proxy \
  --upstream wss://msg-frontier.feishu.cn:443 \
  --listen :9443 \
  --otlp-endpoint localhost:4317 \
  --service-name feishu-ws-proxy \
  --capture-dir /data/capture    # optional binary dump

# Minimum (stdout JSON + OTel spans, no binary capture)
otel-proxy \
  --upstream wss://msg-frontier.feishu.cn:443 \
  --listen :9443
```

---

## 3. OTel Trace Model

### 3.1 Connection-Level Trace

Each WebSocket connection (one per cc-connect instance) gets a top-level trace. This trace
lives for the duration of the connection.

**Trace root**: `feishu.ws.connection`

```
Trace: ws_conn_<id>
│
├── feishu.ws.connection                          (root, SERVER)
│   ├── feishu.ws.upstream_connect                (CLIENT — connecting to feishu)
│   ├── feishu.ws.frame_received  [frame_seq=1]   (CONSUMER — feishu→proxy)
│   ├── feishu.ws.frame_forwarded [frame_seq=1]   (PRODUCER — proxy→cc-connect)
│   ├── feishu.ws.frame_received  [frame_seq=2]   (CONSUMER — cc-connect→proxy)
│   ├── feishu.ws.frame_forwarded [frame_seq=2]   (PRODUCER — proxy→feishu)
│   ├── feishu.ws.frame_received  [frame_seq=3]
│   ├── feishu.ws.frame_forwarded [frame_seq=3]
│   ├── ...                                        (repeating per frame)
│   └── feishu.ws.connection_close                (INTERNAL)
```

**Why a single trace per connection**: frames arrive sequentially on a WS connection.
Putting all frames in one trace makes it trivial to query "show me everything that
happened on this connection in order". The trace duration equals the connection lifetime.

**If connections are long-lived** (days): split into sub-traces. The proxy creates a new
trace every `--max-trace-duration` (default 1 hour), linked by `conn_id`. This prevents
a single trace from accumulating millions of spans.

### 3.2 Span: `feishu.ws.connection`

Created when cc-connect establishes a downstream WS connection to the proxy.

**SpanKind**: `SERVER` (the proxy accepts a WS connection)

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `feishu.ws.conn_id` | string | UUID assigned by proxy |
| `feishu.ws.downstream_addr` | string | `127.0.0.1:43210` (cc-connect's ephemeral port) |
| `feishu.ws.upstream_addr` | string | `msg-frontier.feishu.cn:443` |
| `network.peer.address` | string | Downstream client IP |
| `server.address` | string | `127.0.0.1` |
| `server.port` | int | `9443` |

### 3.3 Span: `feishu.ws.upstream_connect`

Opening the upstream WSS connection to feishu's msg-frontier.

**SpanKind**: `CLIENT`

**Parent**: `feishu.ws.connection`

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `server.address` | string | `msg-frontier.feishu.cn` |
| `server.port` | int | `443` |
| `url.scheme` | string | `wss` |
| `tls.protocol` | string | `1.3` |
| `feishu.ws.conn_id` | string | UUID |

### 3.4 Span: `feishu.ws.frame_received`

A frame was received from one side of the connection. This span represents the
proxy receiving a frame from **either** the upstream (feishu) or downstream (cc-connect).

**SpanKind**: `CONSUMER` (receiving a message from a WebSocket stream)

**Parent**: `feishu.ws.connection` (sibling to all other frame spans)

**Attributes**:

| Attribute | Type | Value | Example |
|-----------|------|-------|---------|
| `feishu.ws.conn_id` | string | UUID | `conn_a1b2c3` |
| `feishu.ws.frame_seq` | int | Monotonic per connection | `42` |
| `feishu.ws.direction` | string | `"recv"` from the proxy's perspective | `"recv"` |
| `feishu.ws.stream` | string | `"upstream"` or `"downstream"` | `"upstream"` |
| `feishu.ws.opcode` | string | WebSocket opcode | `"text"` |
| `feishu.ws.frame_len` | int | Payload length in bytes | `1428` |
| `feishu.ws.payload_truncated` | bool | True if payload exceeded max-log config | `false` |
| `feishu.ws.payload_sha256` | string | SHA-256 of full payload | `abc123...` |
| `feishu.msg_id` | string | Extracted from payload if parseable | `om_abc123` |
| `messaging.system` | string | `"feishu"` | `"feishu"` |
| `messaging.operation` | string | `"receive"` | `"receive"` |

**Status**: `OK` if frame was valid and forwarded; `ERROR` if parse error, protocol violation.

### 3.5 Span: `feishu.ws.frame_forwarded`

A frame was forwarded to the other side. This span is the **paired send** for each
`feishu.ws.frame_received`. The pair shares `frame_seq` and can be joined by the
tag `feishu.ws.paired_frame_seq`.

**SpanKind**: `PRODUCER` (sending a message onward)

**Parent**: `feishu.ws.connection`

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `feishu.ws.conn_id` | string | UUID |
| `feishu.ws.frame_seq` | int | Same seq as the corresponding receive |
| `feishu.ws.direction` | string | `"send"` |
| `feishu.ws.stream` | string | Opposite of the receive stream |
| `feishu.ws.opcode` | string | `"text"` |
| `feishu.ws.frame_len` | int | Payload length |

### 3.6 Frame-Level Pairing and Latency

Every frame that is received and then forwarded produces a natural latency measurement:

```
feishu.ws.frame_received  [ts_recv]
feishu.ws.frame_forwarded [ts_send]
                                  └── latency = ts_send - ts_recv
```

This measures **proxy processing time** — how long between receiving a frame and forwarding
it. In practice this should be sub-millisecond for passthrough frames. For frames where
the proxy extracts and logs msg_id, it may be slightly higher (still < 5ms).

**Additional latency pairs**:

| Pair | What It Measures |
|------|-----------------|
| `frame_received(upstream, recv)` → `frame_forwarded(downstream, send)` | Feishu→cc-connect latency through proxy |
| `frame_received(downstream, recv)` → `frame_forwarded(upstream, send)` | cc-connect→feishu latency through proxy |
| Ping→Pong pair (any direction) | Round-trip time for the remote endpoint |

### 3.7 Span: `feishu.ws.connection_close`

The connection closed (either side initiated).

**SpanKind**: `INTERNAL`

**Parent**: `feishu.ws.connection`

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `feishu.ws.close_code` | int | WebSocket close code (1000, 1006, etc.) |
| `feishu.ws.close_reason` | string | Close reason text |
| `feishu.ws.close_initiator` | string | `"upstream"`, `"downstream"`, or `"proxy"` |
| `feishu.ws.frames_total` | int | Total frames relayed during this connection |
| `feishu.ws.bytes_total` | int | Total bytes relayed (both directions) |
| `feishu.ws.duration_ms` | int | Connection lifetime |

### 3.8 Message-Level Trace (Optional Enhancement)

When the proxy detects a feishu message event (by parsing the frame payload and
extracting `msg_id`), it can optionally create a **message-level sub-trace** that
groups all frames belonging to the same message turn:

```
Trace: msg_om_abc123
│
├── feishu.ws.message_received                   (CONSUMER)
│   └── feishu.ws.frame_received  [upstream]     (child — the raw frame containing this message)
├── feishu.ws.message_ack_sent                   (PRODUCER)
│   └── feishu.ws.frame_forwarded [downstream]
├── feishu.ws.message_response_recv [cc-connect] (CONSUMER)
│   └── feishu.ws.frame_received  [downstream]
└── feishu.ws.message_response_sent [feishu]     (PRODUCER)
    └── feishu.ws.frame_forwarded [upstream]
```

This trace is linked to the connection trace via `trace_id` span link:
- Connection trace contains the frame-by-frame view
- Message trace contains the logical message turn view
- Both share `feishu.msg_id` as the join key

**Implementation note**: message-level traces are **opt-in** via `--enable-msg-traces`.
They require parsing frame payloads as JSON (feishu protocol) to extract `msg_id`.
This adds CPU overhead per frame and is unnecessary if the connection trace provides
enough granularity.

---

## 4. Export Pipeline

### 4.1 OTLP Export

The proxy exports OTel spans directly to a local OTel Collector via gRPC OTLP.

```go
// Go OTel SDK initialization (inside otel-proxy)
exporter, _ := otlptracegrpc.New(ctx,
    otlptracegrpc.WithEndpoint(cfg.OTLPEndpoint),   // "localhost:4317"
    otlptracegrpc.WithInsecure(),                     // loopback, no TLS needed
)
tp := sdktrace.NewTracerProvider(
    sdktrace.WithBatcher(exporter,
        sdktrace.WithBatchTimeout(time.Second),
        sdktrace.WithMaxExportBatchSize(512),
    ),
    sdktrace.WithResource(resource.NewWithAttributes(
        semconv.SchemaURL,
        semconv.ServiceName("feishu-ws-proxy"),
        semconv.ServiceVersion(version),
        attribute.String("deployment.environment", env),
    )),
)
```

### 4.2 Collector Configuration (Same as `otel-cc-connect.md`)

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

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
    namespace: feishu_ws_proxy

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

### 4.3 Fallback: Stdout JSON Lines

The proxy **also** emits JSON lines to stdout (same format as `proxy-intercept.md`
Section 5.2). This serves two purposes:

1. **Local debugging**: `docker logs otel-proxy` shows frame activity in real time
2. **Pipeline redundancy**: if OTel Collector is down, frame data is not lost — Vector
   can still ingest from stdout and forward to ClickHouse

The stdout output is configurable:

| Flag | Default | Effect |
|------|---------|--------|
| `--stdout-json` | `true` | Emit JSON frame lines to stdout |
| `--stdout-json-pretty` | `false` | Pretty-print for human readability |
| `--otlp-export` | `true` | Export OTel spans via OTLP |

Both can be true simultaneously. Spans go to Tempo; JSON lines go to container logs
→ Vector → ClickHouse for the existing `cc.ws_frames` table.

### 4.4 Binary Capture (Optional)

Same as `proxy-intercept.md` Section 7.3: `--capture-dir /data/capture` writes a
compact binary format for offline replay. Unchanged from the existing design.

---

## 5. Metrics (OTel + Prometheus)

The proxy exports OTel metrics (in addition to traces) for operational visibility.

| Metric | Type | Attributes | Description |
|--------|------|------------|-------------|
| `feishu.ws.frames_total` | Counter | `stream`, `direction`, `opcode` | Total frames relayed |
| `feishu.ws.bytes_total` | Counter | `stream`, `direction` | Total bytes relayed |
| `feishu.ws.active_connections` | Gauge | (none) | Current active WS connections |
| `feishu.ws.connection_duration_ms` | Histogram | `close_code` | Connection lifetime distribution |
| `feishu.ws.frame_latency_ms` | Histogram | `stream` | Time from recv to forward per frame |
| `feishu.ws.ping_pong_rtt_ms` | Histogram | `target` (feishu/cc-connect) | Round-trip time from pings |
| `feishu.ws.upstream_reconnects_total` | Counter | (none) | Number of upstream reconnection events |
| `feishu.ws.errors_total` | Counter | `error_type` | Frame parse errors, WS write errors, OTel export errors |

These metrics feed into Grafana for real-time dashboards.

---

## 6. Sampling Strategy

### 6.1 At Current Scale (~540 frames/day)

Sample everything. No sampling needed. All frames become spans.

Estimated daily data:

| Item | Value |
|------|-------|
| Frames/day | ~540 |
| Spans/frame (recv+forward) | ~2 per frame ≈ 1080 spans |
| Connection spans (rare) | ~2 per reconnect ≈ negligible |
| Avg span wire size | ~300 bytes (with attributes) |
| Daily trace data | ~324 KB |
| Tempo 30-day retention | ~9.7 MB |

This is negligible even without compression.

### 6.2 Head-Based Sampling (for Growth)

If volume grows 100x+ (54K frames/day, 108K spans/day), apply head-based sampling:

| Priority | Rule | Sampling Rate |
|----------|------|---------------|
| 1 | Error spans (status=ERROR) | Always sample (100%) |
| 2 | Slow frames (>P99 latency threshold) | Always sample (100%) |
| 3 | First frame of each message (feishu event) | Always sample (100%) |
| 4 | All other frames | 10% random |

Implementation: use OTel `Sampler` with a custom `ShouldSample` function.

### 6.3 Connection Trace Duration Limit

Long-lived connections produce unbounded trace size. The proxy enforces:

- `--max-trace-duration 1h` (default): start a new trace every hour
- New trace inherits `conn_id` and links to previous trace via OTel span links
- Tempo query for a connection: search by `feishu.ws.conn_id` and union all traces

---

## 7. Grafana Integration

### 7.1 Tempo Datasource

Add Tempo as a Grafana datasource. Search by:

- `feishu.ws.conn_id` — all frames for a specific connection
- `feishu.msg_id` — find the connection trace containing a specific message
- `feishu.ws.frame_len > 4096` — find large frames
- `feishu.ws.opcode = "close"` — find connection closures

### 7.2 Trace-to-Logs

Link Tempo traces to ClickHouse log records (from the fallback stdout pipeline) via
`feishu.ws.conn_id` and `frame_seq`. When viewing a trace, click "Related logs" to see
the raw JSON line for that frame.

### 7.3 Dashboards

| Dashboard | Panels | Source |
|-----------|--------|--------|
| **WS Connection Overview** | Active connections, reconnect count, connection duration histogram | OTel metrics |
| **Frame Throughput** | Frames/min by direction, bytes/min, frame size heatmap | OTel metrics |
| **Frame Latency** | Recv→forward latency P50/P90/P99 by stream (upstream/downstream) | OTel metrics + trace durations |
| **Message Turn Explorer** | Search by msg_id, see all frames for that turn in order | Trace search (Tempo) |
| **Error Overview** | Error count by type, close codes, upstream reconnect events | OTel metrics + trace errors |

### 7.4 SLOs from Traces

| SLO | Measure | Source |
|-----|---------|--------|
| Frame forwarding latency P99 < 5ms | `feishu.ws.frame_received` → `feishu.ws.frame_forwarded` | Trace span duration |
| Upstream (feishu) ping RTT P99 < 500ms | Ping→Pong frame pair via feishu | Frame recv→forward latency through feishu |
| Connection uptime > 99.9% | `feishu.ws.connection_close` with code 1000 (normal) vs other | Trace span status |
| OTel export success rate > 99% | OTel exporter error counter vs frames_total | OTel metrics |

---

## 8. Key Design Decisions

### Decision 1: Single Trace per Connection (Not per Frame)

**Chosen**: One trace per connection, with each frame as a child span.

**Alternative considered**: One trace per frame (thousands of tiny traces).
Rejected because:
- Frame traces have no useful parent-child relationship
- Querying "show me all frames for this connection" would require joining
  thousands of small traces by `conn_id` — slow in Tempo
- Connection trace groups everything naturally in a hierarchy

**Consequence**: Long-lived connections produce large traces. Mitigated by
`--max-trace-duration` (hourly trace split).

### Decision 2: Proxy is the Trace Root

**Chosen**: The proxy creates the trace root (`feishu.ws.connection`). cc-connect
creates its own traces (from `otel-cc-connect.md`) that are **not** directly linked
(they run in separate processes with no context propagation).

**Alternative considered**: Propagate trace context from proxy to cc-connect via
WS frame headers. Rejected because:
- cc-connect's Go OTel instrumentation would need to read W3C trace context from
  incoming WS frames (non-trivial)
- Couples proxy and cc-connect implementation
- Proxy's frame-level traces and cc-connect's message-level traces are naturally
  connected via `msg_id` join — no need for technical trace propagation

**Bridge via `msg_id`**: Both proxy spans and cc-connect spans carry `feishu.msg_id`.
Tempo can be queried for both trace sets and they appear as related. This is
sufficient for debugging.

### Decision 3: Dual Export (OTLP + Stdout JSON)

**Chosen**: Export both OTel spans (to Collector) and JSON lines (to stdout).

**Rationale**: OTel is the primary pipeline (traces + metrics), but stdout JSON
provides:
- Real-time human-readable logs (`docker logs`)
- Failover if OTel Collector is down
- Existing ClickHouse `cc.ws_frames` table continues to be populated
- No data loss during transition period

**When to disable stdout**: Once OTel is stable and all consumers have migrated to
Tempo/ClickHouse-OTel, set `--stdout-json false` to reduce log volume.

### Decision 4: Frame Parsing in Proxy vs Collector

**Chosen**: The proxy parses frame payloads to extract `feishu.msg_id` and
populates span attributes.

**Alternative**: Send raw frames to Collector, let Collector processor
extract msg_id. Rejected because:
- Collector processors add complexity and latency
- Proxy already has the frame in memory — parsing is free
- Proxy owns the span creation; splitting responsibility would be confusing

---

## 9. Implementation Plan

### Phase 1: Core Proxy + OTel (Week 1)

- [ ] Fork `feishu-proxy` Go codebase into `otel-proxy`
- [ ] Add OTel Go SDK initialization (OTLP exporter, tracer provider, resource)
- [ ] Instrument: `feishu.ws.connection` span (trace root)
- [ ] Instrument: `feishu.ws.frame_received` + `feishu.ws.frame_forwarded` spans
- [ ] Instrument: `feishu.ws.upstream_connect` span
- [ ] Instrument: `feishu.ws.connection_close` span
- [ ] Dual export: OTLP + stdout JSON (keep existing stdout from feishu-proxy)
- [ ] Test: manual relay, verify spans appear in Tempo

### Phase 2: Metrics + Trace Splitting (Week 1-2)

- [ ] OTel metrics: counters, histograms, gauge
- [ ] Trace duration split (`--max-trace-duration` with span links)
- [ ] Fallback: if OTel export fails, degrade gracefully (log warning, continue)
- [ ] Error spans: WS write errors, parse errors, connection drops

### Phase 3: Message-Level Traces (Week 2, Optional)

- [ ] Frame payload parsing for `feishu.msg_id` extraction
- [ ] Message-level sub-traces (`--enable-msg-traces`)
- [ ] Span links between connection trace and message trace

### Phase 4: Production Hardening (Week 3)

- [ ] Fail-open (same as `proxy-intercept.md` Section 4.3)
- [ ] Resource limits: OTel memory limiter, span queue backpressure
- [ ] Performance benchmark: frames/sec with OTel enabled vs disabled
- [ ] Verify: no regressions in frame forwarding latency

---

## 10. Performance Impact

### 10.1 Overhead of OTel Span Creation

| Operation | Approximate Cost | Notes |
|-----------|-----------------|-------|
| Frame relay (no OTel) | ~0.5 µs | Baseline (memory copy only) |
| Frame relay + stdout JSON log | ~5 µs | JSON serialization + write syscall |
| Frame relay + OTel span creation | ~3 µs | Attribute setting + span start/end |
| Frame relay + OTel + stdout | ~8 µs | Both pipelines |
| Frame relay + OTel + stdout + binary capture | ~15 µs | All three (binary write to file) |

At ~540 frames/day, total OTel overhead per day: ~1.6 ms. At 100x growth (54K frames/day):
~0.16 seconds. Even at 1000x, the overhead is negligible.

### 10.2 Memory Impact

| Item | Size per Frame |
|------|---------------|
| Span object (in-flight) | ~200 bytes |
| Attribute key-value pairs | ~150 bytes (avg) |
| OTel batch buffer | 512 spans × ~350 bytes ≈ 180 KB |
| Total per connection | ~200 KB (mostly idle) |

The OTel batching exporter holds at most 512 spans in memory before flushing. For
a single connection at ~540 frames/day, this is never reached. The batch flushes every
second (configurable) with no backlog.

---

## 11. Migration from feishu-proxy

### 11.1 Drop-in Replacement

`otel-proxy` accepts all flags from `feishu-proxy` plus new OTel flags:

```bash
# Old
feishu-proxy --upstream wss://... --listen :9443

# New (same flags, just renamed binary)
otel-proxy --upstream wss://... --listen :9443
```

New flags all have defaults:
- `--otlp-endpoint` defaults to `localhost:4317` (no-op if collector not present)
- `--stdout-json` defaults to `true` (backward compatible)
- `--enable-msg-traces` defaults to `false` (opt-in)

### 11.2 Transition Steps

1. **Phase 1**: Deploy `otel-proxy` with default settings (stdout ON, OTel ON).
   Existing Vector pipeline keeps working. Tempo receives spans.
2. **Phase 2**: Once Tempo is verified, migrate Grafana dashboards from
   `cc.ws_frames` (ClickHouse) to Tempo trace queries + OTel metrics.
3. **Phase 3**: Disable stdout JSON (`--stdout-json false`). Remove Vector
   config for `ws_frames`. Table remains in ClickHouse for historical data.
4. **Phase 4**: Drop `cc.ws_frames` table after retention period expires.

---

## 12. Alternatives Considered

### Alternative 1: OTel-Instrument cc-connect Only (Skip Proxy)

Already covered in `otel-cc-connect.md`. The problem: cc-connect has no visibility
into raw WS frames. Adding frame capture to cc-connect would require modifying its
WebSocket client code and coupling observability to its release cycle.

**Rejected**: Proxy-based approach is decoupled and provides frame-level visibility
without touching cc-connect.

### Alternative 2: Envoy WASM Filter for WS Frames

Deploy an Envoy sidecar with a WASM filter that captures WS frames and emits OTel spans.
Pros: battle-tested proxy, no custom binary. Cons: Envoy is heavy (~50 MB binary),
WASM filter for WS frame capture is non-trivial, adds a sidecar container (more
complex than a subprocess).

**Rejected**: Too heavy for the scale. A 5 MB static Go binary is simpler.

### Alternative 3: OTel Collector Receives WS Frames Directly

Make the proxy a dumb relay (no OTel), then have the OTel Collector accept WS events
and create spans via a custom receiver. Pros: proxy stays simple. Cons: OTel Collector
custom receivers are in development (not stable); would couple frame parsing to the
Collector's config; harder to test and iterate.

**Rejected**: OTel SDK in the proxy is the stable, well-tested path.

### Alternative 4: Modify Existing feishu-proxy to Emit OTel-Compatible JSON

Instead of a new binary, add OTel-format JSON fields to feishu-proxy's stdout output.
Then configure Vector to use the `otel_logs` source to ingest these as OTel spans.
Pros: no new binary, no OTel SDK dependency. Cons: OTel spans constructed by Vector
from JSON are second-class; no native span duration measurement; no metrics;
Vector's OTel support is less mature than the Go SDK.

**Rejected**: Direct OTel SDK export is more reliable and feature-complete.

---

## 13. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Trace root | Connection-level trace | Groups all frames naturally; easy to query "everything for this connection" |
| Frame grouping | Child spans of connection trace | Tempo shows hierarchy; recv+forward are siblings under connection |
| Export pipeline | OTel SDK → OTLP gRPC → Collector | Native, stable, high-performance |
| Dual export | OTel + stdout JSON | Backward compatibility + failover |
| Message-level traces | Opt-in (`--enable-msg-traces`) | CPU overhead for frame parsing; not needed for frame-level debugging |
| Trace splitting | Hourly via `--max-trace-duration` | Prevents unbounded trace growth on long-lived connections |
| cc-connect coupling | None (msg_id join only) | Proxy and cc-connect remain independent |
| Migration | Drop-in replacement for feishu-proxy | Same flags, same ports, same behavior with added OTel |

---

## 14. Open Questions

| Question | Options | Needed From |
|----------|---------|-------------|
| OTel Collector deployment | (a) Sidecar container (b) Centralized cluster collector | Depends on Tempo deployment plan |
| Trace retention in Tempo | (a) 7 days (b) 30 days (c) Match ClickHouse 90-day retention | Observability SLO review |
| Move away from stdout JSON entirely? | (a) Yes, once OTel is stable (b) Keep both forever (belt and suspenders) | Operator preference |
| cc-connect OTel traces (from `otel-cc-connect.md`) | Will they be implemented? If so, msg_id join works both ways | cc-connect team |

---

> **Summary**: `otel-proxy` merges the MITM WS proxy from `proxy-intercept.md` with the
> OTel instrumentation model from `otel-cc-connect.md`. Every WebSocket frame becomes an
> OTel span, grouped into a connection-level trace, exported via OTLP to Tempo + Prometheus.
> The proxy is a drop-in replacement for `feishu-proxy` with zero behavioral change and
> negligible performance overhead (~3 µs per frame). Dual stdout JSON export ensures
> backward compatibility and failover during migration.
>
> ／人◕ ‿‿ ◕人＼
