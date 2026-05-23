---
decision: 稍微有点不确定等专家再审一轮
---

# Cross-Container Trace Correlation

**Date:** 2026-05-23
**Status:** Design proposal
**Scope:** Trace context propagation across container boundaries: Feishu WebSocket receive in cc-connect, through agent processing, to HTTP dispatch into the boss container and back. Covers W3C TraceContext propagation via HTTP headers, unified OTel Collector export, and Grafana Tempo visualization for end-to-end traces that span two containers.

---

## 1. Problem

Existing OTel traces are container-local:

| Trace Design | Container Scope | Cross-Container? |
|---|---|---|
| `otel-cc-connect.md` | cc-connect only (Feishu WS -> Claude API -> Feishu send) | No |
| `otel-mcp.md` | MCP proxy + server | stdio/SSE within same container |
| `otel-patrol.md` | Patrol agents within boss container | No |
| `kafka-message-bus.md` | Event bus, not traces | No trace correlation |

When a Feishu message triggers an infra operation that dispatches to the boss container, the trace splits:

```
Feishu message
    │
    ▼
cc-connect container
    ├── feishu.message.receive       (trace A)
    ├── cc.agent.process
    │   └── claude.api.call
    ├── cc.boss.dispatch  ──HTTP──►  boss container
    │                                   └── boss.command.execute  (trace B, orphaned)
    └── feishu.message.send           (trace A, no link to boss outcome)
```

Without cross-container trace correlation:

- **Orphaned boss spans**: The boss container creates spans but they lack a parent TraceID linking back to the original Feishu message. Operators see a boss command span but cannot answer "which message caused this?"
- **Blind spots in latency breakdown**: If the boss dispatch takes 30s, is the bottleneck in cc-connect (Claude deciding what to do) or in boss (executing the command)? Without a shared trace, you cannot attribute time.
- **No causal chain for errors**: A Feishu user sees "command failed" but the root cause is in the boss container (e.g., SSH timeout, disk full). The trace should thread through both containers to pin the failure location.

## 2. Target Architecture

### 2.1 System Flow

```
┌─────────────────────┐     ┌──────────────────────┐     ┌─────────────────────┐
│    Feishu           │     │    cc-connect         │     │    Boss Container   │
│    WebSocket        │────►│    (Go, OTel inst.)   │────►│    (Go/Ruby)        │
│                     │     │                       │     │                     │
│                     │     │  trace root created   │     │  child span created │
│                     │     │  at msg receive       │     │  via traceparent    │
│                     │     │                       │     │  header extraction  │
│                     │     │  HTTP POST /dispatch  │     │                     │
│                     │     │  with traceparent     │     │  SSH into remote    │
│                     │     │  header               │     │  or exec local cmd  │
│                     │     │                       │     │                     │
│                     │◄────│  response to Feishu   │◄────│  response returned  │
└─────────────────────┘     └──────────────────────┘     └─────────────────────┘
                                  │                              │
                                  └──────────┬───────────────────┘
                                             │ OTLP (gRPC)
                                             ▼
                                  ┌─────────────────────┐
                                  │   OTel Collector    │
                                  │   (otel-collector)  │
                                  │                     │
                                  │  fan-out to:        │
                                  │  - Tempo (traces)   │
                                  │  - Prometheus       │
                                  │  - ClickHouse       │
                                  └─────────────────────┘
```

Both containers export OTLP to the **same OTel Collector** (or collector cluster). This is critical -- a single Tempo backend unifies traces from multiple containers by TraceID.

### 2.2 Components

| Component | Role |
|-----------|------|
| **cc-connect container** | Receives Feishu events, processes them via agent loop, dispatches to boss via HTTP when the agent decides to run an infra command. Creates the trace root. |
| **Boss container** (kyb-infra-boss) | Receives HTTP dispatch requests from cc-connect, executes commands (SSH, Docker, kyb CLI), returns results. Creates child spans from traceparent. |
| **OTel Collector** | Single OTLP receiver for both containers. Batches, samples, and fan-outs to Tempo, Prometheus, ClickHouse. Must be reachable from both containers (same Docker network or via host). |
| **Tempo / Grafana** | Unified trace storage and query UI. Tempo stores traces by TraceID regardless of which container produced each span. |

### 2.3 Network Topology

```
Docker network (kyb-infra / bridge)
    │
    ├── cc-connect (172.x.x.1:8080)
    │     HTTP POST /dispatch  ───►  boss (172.x.x.2:9090)
    │     OTLP gRPC :4317     ───►  otel-collector (172.x.x.3:4317)
    │
    ├── boss (172.x.x.2:9090)
    │     OTLP gRPC :4317     ───►  otel-collector (172.x.x.3:4317)
    │
    └── otel-collector (172.x.x.3)
          exports to Tempo, Prometheus, ClickHouse
```

Containers communicate over the internal Docker network (no auth needed, low latency). OTLP export from both containers to collector over same network.

---

## 3. Trace Model

### 3.1 Complete Trace DAG (Cross-Container)

A single user message that triggers an infra operation produces this span tree:

```
Container: cc-connect                                     Container: boss
┌─────────────────────────────────┐
│ feishu.message.receive (root)   │
│   SpanKind: CONSUMER           │
│   ├── cc.message.route         │
│   ├── cc.agent.process         │
│   │   ├── claude.api.call #1   │
│   │   ├── cc.boss.dispatch ────┼──── HTTP ────►  ┌─────────────────────────┐
│   │   │                       │                  │ boss.request.receive     │
│   │   │                       │                  │   SpanKind: SERVER       │
│   │   │                       │                  │   ├── boss.auth.check    │
│   │   │                       │                  │   ├── boss.command.parse │
│   │   │                       │                  │   ├── boss.command.exec  │
│   │   │                       │                  │   │   ├── boss.ssh.exec  │
│   │   │                       │                  │   │   └── boss.result    │
│   │   │                       │                  │   └── boss.response.send │
│   │   │                       │                  └─────────────────────────┘
│   │   └── cc.boss.result     │                           │
│   └── feishu.message.send    │◄──── HTTP 200 ────────────┘
└─────────────────────────────────┘
```

**Key property**: Every span in both containers shares the **same TraceID**. The TraceID is created by cc-connect at `feishu.message.receive` and propagated to the boss container via the HTTP `traceparent` header.

### 3.2 Span Table

| Span Name | Parent | Container | Kind | What It Measures |
|-----------|--------|-----------|------|-----------------|
| `feishu.message.receive` | (root) | cc-connect | `CONSUMER` | Full end-to-end message turn |
| `cc.message.route` | `feishu.message.receive` | cc-connect | `INTERNAL` | Session lookup, handler routing |
| `cc.agent.process` | `feishu.message.receive` | cc-connect | `INTERNAL` | Agent loop (Claude calls + tool execution) |
| `claude.api.call` | `cc.agent.process` | cc-connect | `CLIENT` | HTTP request to Anthropic API |
| `cc.boss.dispatch` | `cc.agent.process` | cc-connect | `CLIENT` | HTTP POST to boss API (outbound) |
| `cc.boss.result` | `cc.agent.process` | cc-connect | `INTERNAL` | Processing boss response |
| `boss.request.receive` | `cc.boss.dispatch` | boss | `SERVER` | Inbound HTTP request from cc-connect |
| `boss.auth.check` | `boss.request.receive` | boss | `INTERNAL` | Token validation or auth check |
| `boss.command.parse` | `boss.request.receive` | boss | `INTERNAL` | Command deserialization and validation |
| `boss.command.exec` | `boss.request.receive` | boss | `INTERNAL` | Command execution (dispatch, run, collect output) |
| `boss.ssh.exec` | `boss.command.exec` | boss | `CLIENT` | SSH to remote cluster (optional, if remote) |
| `boss.response.send` | `boss.request.receive` | boss | `INTERNAL` | Serialize and send HTTP response |
| `feishu.message.send` | `feishu.message.receive` | cc-connect | `PRODUCER` | Send response to Feishu |

### 3.3 New Span Details

Spans already defined in `otel-cc-connect.md` (`feishu.message.receive`, `cc.message.route`, `cc.agent.process`, `claude.api.call`, `feishu.message.send`) are reused without modification. The new cross-container spans are:

#### Span: `cc.boss.dispatch`

Created when cc-connect's agent decides to execute an infra command via the boss API. The agent returns a structured command (tool call result), and cc-connect's bridge layer translates it into an HTTP request to the boss container.

**SpanKind**: `CLIENT` (outbound HTTP call)

**Parent**: `cc.agent.process`

**Attributes**:

| Attribute | Type | Value | Source |
|-----------|------|-------|--------|
| `boss.api.endpoint` | string | `/api/dispatch` | Boss API route |
| `boss.api.method` | string | `POST` | HTTP method |
| `boss.command.type` | string | `shell` / `docker` / `kyb` / `ssh` | Command category |
| `boss.command.id` | string | UUID | Generated by cc-connect |
| `boss.target` | string | `local` / `sim` / `nuc8` | Target cluster for the command |
| `boss.command.timeout_ms` | int | 30000 | Expected execution timeout |
| `http.request.method` | string | `POST` | OTel semantic convention |
| `server.address` | string | `kyb-infra-boss:9090` | OTel semantic convention |
| `server.port` | int | 9090 | OTel semantic convention |

**Events**:

| Event name | Condition | Attributes |
|-----------|-----------|------------|
| `boss.dispatch.request_body` | Sampled (1%) | `body_preview` (first 256 chars of command) |

**Status**: `OK` if HTTP 200 received; `ERROR` if timeout, connection refused, or non-2xx response.

**Duration**: Covers the full HTTP round-trip time (send request + wait for response).

---

#### Span: `cc.boss.result`

After the boss returns a response, cc-connect may post-process the result (e.g., format it for the agent to interpret). This span captures that post-processing.

**SpanKind**: `INTERNAL`

**Parent**: `cc.agent.process`

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `boss.response.status_code` | int | 200 |
| `boss.response.body_length` | int | Chars of response body |
| `boss.response.has_error` | bool | Whether response contains error |
| `boss.response.parse_duration_ms` | int | Time to parse the response |

**Status**: `OK` if result was parsed successfully; `ERROR` if response could not be parsed.

---

#### Span: `boss.request.receive`

The root span in the boss container. Created when boss receives the HTTP POST from cc-connect. This span's context is derived from the incoming `traceparent` header -- it is a child of `cc.boss.dispatch`.

**SpanKind**: `SERVER` (inbound HTTP request)

**Parent**: `cc.boss.dispatch` (via W3C TraceContext header)

**Attributes**:

| Attribute | Type | Value | Source |
|-----------|------|-------|--------|
| `http.request.method` | string | `POST` | HTTP method |
| `url.path` | string | `/api/dispatch` | URL path |
| `http.request.header.traceparent` | string | (masked) | Trace context |
| `http.request.body.length` | int | Body size in bytes | Request |
| `boss.command.id` | string | UUID | Request body |
| `boss.command.type` | string | `shell` / `docker` / `kyb` / `ssh` | Request body |
| `boss.target` | string | `local` / `sim` / `nuc8` | Request body |
| `network.peer.address` | string | `kyb-infra-cc-connect` | OTel semantic convention |
| `network.peer.port` | int | Ephemeral port | OTel semantic convention |

**Events**:

| Event name | Condition | Attributes |
|-----------|-----------|------------|
| `boss.request.body` | Sampled (1%) | `body_preview` (first 256 chars) |

**Status**: `OK` if request parsed and dispatched; `ERROR` if body malformed or auth fails.

---

#### Span: `boss.command.parse`

Parsing and validating the incoming command. Ensures the command type is allowed, the target is reachable, and parameters are valid.

**SpanKind**: `INTERNAL`

**Parent**: `boss.request.receive`

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `boss.command.type` | string | `shell` / `docker` / `kyb` / `ssh` |
| `boss.command.validation` | string | `valid` / `invalid` / `unsupported` |
| `boss.command.timeout_ms` | int | Timeout parsed from request |
| `boss.command.sanitized` | bool | Whether command was sanitized for injection prevention |

**Status**: `OK` if command is valid; `ERROR` if command type is unknown or parameters fail validation.

---

#### Span: `boss.command.exec`

The actual execution of the command. This is the core span -- its duration is the wall-clock time of the operation the user cares about.

**SpanKind**: `INTERNAL`

**Parent**: `boss.request.receive`

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `boss.command.type` | string | `shell` / `docker` / `kyb` / `ssh` |
| `boss.target` | string | `local` / `sim` / `nuc8` |
| `boss.command.exit_code` | int | 0 for success, non-zero for error |
| `boss.command.duration_ms` | int | Execution wall time |
| `boss.command.stdout_length` | int | Bytes of stdout |
| `boss.command.stderr_length` | int | Bytes of stderr |
| `boss.command.error` | string | Error message if command failed |

**Events**:

| Event name | Condition | Attributes |
|-----------|-----------|------------|
| `boss.command.stdout_preview` | Sampled (1%) | `preview` (first 512 chars of stdout) |
| `boss.command.stderr_preview` | On error | `preview` (first 512 chars of stderr) |

**Status**: `OK` if command completed (any exit code); `ERROR` if command could not be started (e.g., SSH unreachable, Docker daemon down).

**Note on exit codes**: A non-zero exit code from the target command is **not** an error in the tracing sense -- the command ran successfully and produced an output. The span status should be `OK` and the exit code recorded as an attribute. Only infrastructure failures (SSH timeout, container not found) should set span status to `ERROR`.

---

#### Span: `boss.ssh.exec` (Optional)

If the command targets a remote cluster (sim, nuc8), boss executes it via SSH. This span wraps the SSH call itself.

**SpanKind**: `CLIENT` (outbound SSH)

**Parent**: `boss.command.exec`

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `ssh.target.host` | string | `sim` / `nuc8` / Tailscale IP |
| `ssh.target.user` | string | `dongqs` |
| `ssh.target.port` | int | 22 |
| `ssh.connection.type` | string | `direct` / `multiplex` |
| `ssh.command.preview` | string | First 128 chars of SSH command |
| `ssh.exit_code` | int | SSH session exit code |
| `ssh.duration_ms` | int | SSH round-trip time |

**Events**:

| Event name | Condition | Attributes |
|-----------|-----------|------------|
| `ssh.connection.established` | On connect | `latency_ms` |
| `ssh.connection.failed` | On failure | `error` |
| `ssh.multiplex.hit` | If ControlMaster socket reused | (none) |

**Status**: `OK` if SSH completed; `ERROR` if SSH connection failed, timed out, or auth failed.

---

#### Span: `boss.response.send`

Serializing the command result into an HTTP response and sending it back to cc-connect.

**SpanKind**: `INTERNAL`

**Parent**: `boss.request.receive`

**Attributes**:

| Attribute | Type | Value |
|-----------|------|-------|
| `http.response.status_code` | int | 200 / 400 / 500 |
| `http.response.body.length` | int | Body size in bytes |
| `boss.response.has_error` | bool | Whether response indicates error |
| `boss.response.serialize_duration_ms` | int | JSON serialization time |

**Status**: `OK` if response sent; `ERROR` if write fails (should not happen in practice).

---

## 4. Context Propagation

### 4.1 W3C TraceContext via HTTP Headers

The only cross-container boundary is the HTTP call from cc-connect to boss. Context is propagated using the standard **W3C TraceContext** protocol.

**cc-connect side (producer):**

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// During cc.agent.process, when dispatching to boss:
func dispatchToBoss(ctx context.Context, cmd BossCommand) (*BossResponse, error) {
    ctx, span := tracer.Start(ctx, "cc.boss.dispatch",
        trace.WithSpanKind(trace.SpanKindClient),
    )
    defer span.End()
    
    body, _ := json.Marshal(cmd)
    req, _ := http.NewRequestWithContext(ctx, "POST",
        "http://kyb-infra-boss:9090/api/dispatch",
        bytes.NewReader(body),
    )
    
    // Use otelhttp to automatically inject traceparent header
    client := http.Client{
        Transport: otelhttp.NewTransport(http.DefaultTransport),
    }
    
    resp, err := client.Do(req)
    // ...
}
```

The `otelhttp` transport automatically:
1. Serializes the current span context into the W3C `traceparent` header
2. Sends `tracestate` for additional vendor-specific metadata
3. Creates a child span for the HTTP call (already handled by the manual `cc.boss.dispatch` span above, so use `otelhttp.WithNoopTracing()` or disable the automatic HTTP span to avoid double-spans)

**Alternative: manual header injection without otelhttp:**

```go
import (
    "go.opentelemetry.io/otel/propagation"
)

func dispatchToBoss(ctx context.Context, cmd BossCommand) (*BossResponse, error) {
    ctx, span := tracer.Start(ctx, "cc.boss.dispatch",
        trace.WithSpanKind(trace.SpanKindClient),
    )
    defer span.End()
    
    body, _ := json.Marshal(cmd)
    req, _ := http.NewRequestWithContext(ctx, "POST",
        "http://kyb-infra-boss:9090/api/dispatch",
        bytes.NewReader(body),
    )
    
    // Manual header injection
    propagator := propagation.TraceContext{}
    propagator.Inject(ctx, propagation.HeaderCarrier(req.Header))
    
    resp, err := http.DefaultClient.Do(req)
    // ...
}
```

**HTTP request on the wire:**

```
POST /api/dispatch HTTP/1.1
Host: kyb-infra-boss:9090
Content-Type: application/json
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
tracestate: cc=agent_loop_turn=2

{"type": "shell", "target": "sim", "command": "df -h /", "timeout_ms": 30000, "command_id": "cmd_abc123"}
```

**Boss side (consumer):**

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

func handleDispatch(w http.ResponseWriter, r *http.Request) {
    // Extract trace context from incoming headers
    propagator := propagation.TraceContext{}
    ctx := propagator.Extract(r.Context(), propagation.HeaderCarrier(r.Header))
    
    // Create child span. This span's parent is cc.boss.dispatch in the
    // cc-connect container. They share the same TraceID.
    ctx, span := tracer.Start(ctx, "boss.request.receive",
        trace.WithSpanKind(trace.SpanKindServer),
    )
    defer span.End()
    
    span.SetAttributes(
        attribute.String("boss.command.id", r.Header.Get("X-Command-Id")),
        // ...
    )
    
    // Parse body, execute, respond...
    cmd := parseCommand(r.Body)
    result := executeCommand(ctx, cmd)
    respondJSON(w, result)
}
```

### 4.2 Header Format

**traceparent** (required):

```
traceparent: 00-<trace-id>-<parent-span-id>-<trace-flags>
```

| Field | Length | Example | Description |
|-------|--------|---------|-------------|
| Version | 2 hex | `00` | Version 0 (current standard) |
| TraceID | 32 hex | `0af7651916cd43dd8448eb211c80319c` | Shared across all spans in both containers |
| ParentSpanID | 16 hex | `b7ad6b7169203331` | The `cc.boss.dispatch` span ID |
| TraceFlags | 2 hex | `01` | `01` = sampled (recorded) |

**tracestate** (optional):

```
tracestate: cc=agent_loop_turn=2
```

Carries vendor-specific data. Used here to pass cc-connect agent state (e.g., agent loop turn count) to the boss trace. The boss does not need to parse this -- it is carried along for debugging in Tempo.

### 4.3 Propagation Guarantees

| Condition | Behavior |
|-----------|----------|
| No `traceparent` header present | Boss creates a **new root span** (orphaned trace). The trace will not be connected to cc-connect's trace. Both are still exported; they just lack the parent-child link. |
| Malformed `traceparent` | Boss logs warning at WARN level, treats as absent, creates new root span. |
| `trace-flags` = `00` (not recorded) | Boss still extracts and propagates context, but may skip span export if head sampling decision was already "do not record". |
| Boss response includes `traceparent` | Not required (boss is the last hop). If cc-connect needs to verify trace continuity, boss can echo back the `traceparent` in response headers for cc-connect to validate. |

### 4.4 What Happens When Boss Is Unreachable

If the boss container is down or the HTTP request times out:

1. `cc.boss.dispatch` span ends with `status=ERROR`
2. Span records `error.type` = `connection_refused` or `deadline_exceeded`
3. `cc.agent.process` handles the error (retry or report failure to user)
4. No spans are created on the boss side (never reached)
5. The trace is complete but shows a gap at the container boundary -- Tempo shows the error on the cc-connect side

This is the correct behavior: the trace accurately reflects that the command never reached the boss.

---

## 5. Boss HTTP API Contract

### 5.1 Endpoint: `POST /api/dispatch`

**Request**:

```json
{
    "command_id": "cmd_abc123",
    "type": "shell",
    "target": "local",
    "command": "df -h /",
    "timeout_ms": 30000,
    "env": {
        "PATH": "/usr/local/bin:/usr/bin:/bin"
    }
}
```

| Field | Type | Allowed Values |
|-------|------|---------------|
| `command_id` | string | UUID (generated by cc-connect) |
| `type` | string | `shell`, `docker`, `kyb`, `ssh` |
| `target` | string | `local`, `sim`, `nuc8` |
| `command` | string | The command to execute |
| `timeout_ms` | int | Max execution time (1000-300000) |
| `env` | object | Optional environment overrides |

**Response (200)**:

```json
{
    "command_id": "cmd_abc123",
    "success": true,
    "exit_code": 0,
    "stdout": "Filesystem      Size  Used Avail Use% Mounted on\n/dev/sda1        40G   12G   28G  30% /\n",
    "stderr": "",
    "duration_ms": 234,
    "target": "sim",
    "error": null
}
```

**Response (400)**:

```json
{
    "command_id": "cmd_abc123",
    "success": false,
    "error": "unknown_command_type: kubernetes"
}
```

**Response (500)**:

```json
{
    "command_id": "cmd_abc123",
    "success": false,
    "error": "ssh_connection_failed: dial tcp 100.113.24.32:22: i/o timeout"
}
```

### 5.2 Authentication

For initial deployment: **no authentication** (containers on internal Docker network only). The attacker would need container breakout to reach the API. If needed later:
- Shared pre-shared key in HTTP header `X-Boss-Token`
- mTLS between cc-connect and boss containers
- JWT signed by a shared secret (e.g., from Feishu app secret)

### 5.3 OTel Context in Response

Boss should include trace context in the response for observability:

```
HTTP/1.1 200 OK
Content-Type: application/json
X-Boss-TraceID: 0af7651916cd43dd8448eb211c80319c
X-Boss-SpanID: 8e6c9d8b2f4a1e3c

{...}
```

This allows cc-connect to log the boss-side trace IDs for manual correlation, and makes debugging easier (you can grep for `X-Boss-TraceID` in logs and immediately find both halves of the trace).

---

## 6. OTel Collector Pipeline

### 6.1 Unified Collector Config

Both containers export to the same OTel Collector. The collector config is nearly identical to the one in `otel-cc-connect.md`:

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
  attributes:
    actions:
      # Enrich spans with container identity
      - key: container.name
        value: "${CONTAINER_NAME}"
        action: upsert
      - key: container.host
        value: "${HOSTNAME}"
        action: upsert

exporters:
  otlp/tempo:
    endpoint: tempo.monitoring:4317
    tls:
      insecure: true
  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: kyb_infra

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch, attributes]
      exporters: [otlp/tempo]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
```

The `attributes` processor enriches every span with the originating container's name. This is how Tempo/Grafana distinguish between cc-connect spans and boss spans -- by `container.name` or `service.name`.

### 6.2 Service Name Convention

| Container | OTel `service.name` | `container.name` |
|-----------|---------------------|------------------|
| cc-connect | `cc-connect` | `kyb-infra-cc-connect` |
| Boss | `kyb-infra-boss` | `kyb-infra-boss` |
| OTel Collector | `otel-collector` | `kyb-infra-otel-collector` |

Set via environment variable in each container:

```bash
# In cc-connect container
OTEL_SERVICE_NAME=cc-connect

# In boss container
OTEL_SERVICE_NAME=kyb-infra-boss
```

### 6.3 ClickHouse Schema (Shared Span Table)

No new table needed. The existing `infra.otel_spans` table (designed in `otel-mcp.md`) serves all services:

```sql
CREATE TABLE infra.otel_spans (
  timestamp DateTime64(9),
  trace_id String,
  span_id String,
  parent_span_id String,
  trace_state String,
  span_name String,
  span_kind LowCardinality(String),
  service_name String,
  resource_attributes String,   -- JSON
  scope_name String,
  span_attributes String,       -- JSON
  duration_ns Int64,
  status_code LowCardinality(String),
  status_message String
) ENGINE = MergeTree()
ORDER BY (service_name, timestamp);
```

Cross-container trace query example:

```sql
-- Find all spans for a trace that crosses containers
SELECT service_name, span_name, span_kind, duration_ns, status_code
FROM infra.otel_spans
WHERE trace_id = '0af7651916cd43dd8448eb211c80319c'
ORDER BY timestamp;
```

Result:

```
service_name     | span_name              | kind     | duration_ns | status
cc-connect       | feishu.message.receive | CONSUMER | 45234000000 | OK
cc-connect       | cc.message.route       | INTERNAL |     1200000 | OK
cc-connect       | cc.agent.process       | INTERNAL | 45000000000 | OK
cc-connect       | claude.api.call        | CLIENT   | 21000000000 | OK
cc-connect       | cc.boss.dispatch       | CLIENT   |   534000000 | OK
kyb-infra-boss   | boss.request.receive   | SERVER   |   530000000 | OK
kyb-infra-boss   | boss.command.parse     | INTERNAL |      500000 | OK
kyb-infra-boss   | boss.command.exec      | INTERNAL |   520000000 | OK
kyb-infra-boss   | boss.ssh.exec          | CLIENT   |   490000000 | OK
kyb-infra-boss   | boss.response.send     | INTERNAL |     1000000 | OK
cc-connect       | cc.boss.result         | INTERNAL |     1000000 | OK
cc-connect       | feishu.message.send    | PRODUCER |     2000000 | OK
```

The critical rows are the boundary:
| `cc-connect` | `cc.boss.dispatch` | `CLIENT` | 534ms | OK |
| `kyb-infra-boss` | `boss.request.receive` | `SERVER` | 530ms | OK |

These two spans share the same TraceID but have `parent_span_id` linking them. `boss.request.receive`'s `parent_span_id` = the span_id of `cc.boss.dispatch`.

---

## 7. Grafana / Tempo Visualization

### 7.1 Trace View

In Grafana Tempo, a cross-container trace appears as a single waterfall with two service columns:

```
Service: cc-connect                    Service: kyb-infra-boss
─────────────────────────────────      ────────────────────────────
feishu.message.receive [45.2s]         (no spans until HTTP call)
├─ cc.message.route [1.2ms]
├─ cc.agent.process [45.0s]
│  ├─ claude.api.call [21.0s]
│  ├─ cc.boss.dispatch [534ms] ────►  boss.request.receive [530ms]
│  │                                   ├─ boss.command.parse [0.5ms]
│  │                                   ├─ boss.command.exec [520ms]
│  │                                   │  └─ boss.ssh.exec [490ms]
│  │                                   └─ boss.response.send [1ms]
│  └─ cc.boss.result [1ms]
└─ feishu.message.send [2ms]
```

Tempo groups spans by `service.name` by default. The trace above shows the full end-to-end picture -- you can see that most of the 534ms boss dispatch time is actually SSH execution (490ms), not parsing or overhead.

### 7.2 Service Graph

Tempo's Service Graph feature automatically builds a dependency graph from traces:

```
cc-connect ──HTTP──► kyb-infra-boss
    │                     │
    │                     └──SSH──► sim (remote host)
    │
    └──HTTPS──► api.anthropic.com
```

This is derived from span kind pairs (CLIENT -> SERVER matching by TraceID). The cross-container link shows up automatically once both containers export to the same Tempo backend.

### 7.3 Key Queries

**Find all traces where boss dispatch failed:**

```
{service.name="cc-connect" && span.name="cc.boss.dispatch" && status="error"}
```

**Find slow boss command executions:**

```
{service.name="kyb-infra-boss" && span.name="boss.command.exec"}
| duration > 10s
```

**Correlate Feishu message with boss command:**

```
{service.name="cc-connect" && span.name="feishu.message.receive"}
| duration > 10s
| filter: has span with service.name="kyb-infra-boss"
```

The last query returns only those traces that actually crossed the container boundary, filtering out simple message-only traces.

---

## 8. Derived Metrics

### 8.1 From Trace Data

| Metric | Type | Source | Attributes |
|--------|------|--------|------------|
| `boss.dispatch.duration_ms` | Histogram | `cc.boss.dispatch` span duration | `target`, `command_type`, `status` |
| `boss.execution.duration_ms` | Histogram | `boss.command.exec` span duration | `target`, `command_type`, `exit_code` |
| `boss.ssh.latency_ms` | Histogram | `boss.ssh.exec` span duration | `target_host` |
| `boss.dispatch.total` | Counter | `cc.boss.dispatch` span count | `target`, `command_type`, `status` |
| `boss.command.failures_total` | Counter | `boss.command.exec` where `status=ERROR` | `target`, `error_type` |
| `cross_container.traces_total` | Counter | All traces with spans from both `cc-connect` and `kyb-infra-boss` services | (none) |
| `cross_container.traces_duration_ms` | Histogram | Duration from first cc-connect span to last boss span | (none) |

### 8.2 Prometheus Recording Rules

```yaml
groups:
  - name: boss_operation_metrics
    interval: 1m
    rules:
      - record: boss:dispatch_p50
        expr: histogram_quantile(0.5, rate(boss_dispatch_duration_ms_bucket[5m]))
      - record: boss:dispatch_p99
        expr: histogram_quantile(0.99, rate(boss_dispatch_duration_ms_bucket[5m]))
      - record: boss:ssh_p50
        expr: histogram_quantile(0.5, rate(boss_ssh_latency_ms_bucket[5m]))
      - record: boss:dispatch_error_rate
        expr: rate(boss_dispatch_failures_total[5m]) / rate(boss_dispatch_total[5m])
```

### 8.3 Alert Rules

| Rule | Expression | Level | Description |
|------|-----------|-------|-------------|
| BossDispatchHighLatency | `boss:dispatch_p99 > 30s` | P2 | Boss dispatch is unusually slow |
| BossCommandFailure | `rate(boss_command_failures_total[5m]) > 0` | P1 | Boss commands failing |
| BossDispatchError | `boss:dispatch_error_rate > 0.1` | P2 | >10% of dispatches fail |
| SSHUnreachable | `rate(boss_ssh_latency_ms_count{target_host="sim"}[5m]) == 0 AND rate(boss_dispatch_total{target="sim"}[5m]) > 0` | P1 | SSH to sim failing but commands still being dispatched |
| NoCrossContainerTraces | `rate(cross_container_traces_total[10m]) == 0` | P1 | No cross-container activity detected (cc-connect to boss link may be broken) |

---

## 9. Implementation Plan

### Phase 1: Boss HTTP API + OTel Instrumentation (P0)

| Task | Owner | Depends On |
|------|-------|-----------|
| 1. Add `/api/dispatch` endpoint to boss container (lightweight HTTP server) | Boss agent | None |
| 2. Initialize OTel Go/Ruby SDK in boss, export to OTel Collector | Boss agent | OTel Collector deployment |
| 3. Implement span creation for `boss.request.receive`, `boss.command.exec`, `boss.response.send` | Boss agent | Task 2 |
| 4. Implement W3C TraceContext extraction from incoming headers | Boss agent | Task 1, 2 |
| 5. Deploy and verify: send test command from curl, verify spans in Tempo | Boss agent | Tasks 1-4 |

### Phase 2: cc-connect Producer Side (P0)

| Task | Owner | Depends On |
|------|-------|-----------|
| 6. Add `cc.boss.dispatch` span creation in cc-connect's agent loop, replacing raw HTTP call | cc-connect agent | Phase 1 |
| 7. Implement W3C TraceContext injection into HTTP headers to boss | cc-connect agent | Task 6 |
| 8. Add `cc.boss.result` span for response post-processing | cc-connect agent | Task 6 |
| 9. Update cc-connect OTel config (if needed) to ensure export to same collector | cc-connect agent | Task 2 |

### Phase 3: Observation + Dashboards (P1)

| Task | Owner | Depends On |
|------|-------|-----------|
| 10. Configure Tempo to search by cross-container attributes | Infra | Phase 2 |
| 11. Verify service graph shows cc-connect -> boss edge | Infra | Phase 2 |
| 12. Create Grafana dashboard: cross-container trace summary | Infra | Phase 2 |
| 13. Add derived metrics (histograms for dispatch, execution, SSH latency) | Infra | Phase 2 |

### Phase 4: Hardening (P2)

| Task | Owner | Depends On |
|------|-------|-----------|
| 14. Add auth to boss API (shared token or mTLS) | Boss agent | Phase 1 |
| 15. Add boss response validation (cc-connect checks response integrity) | cc-connect agent | Phase 2 |
| 16. Implement retry with backoff for transient boss failures | cc-connect agent | Phase 2 |
| 17. Tail-based sampling: ensure error/latency traces always sampled | Infra | Phase 3 |

---

## 10. Sampling Strategy

### 10.1 Volume Estimate

| Item | Value |
|------|-------|
| Messages/day (cc-connect) | ~90 |
| Fraction dispatching to boss | ~10% (~9/day) |
| Spans per cross-container trace | ~12 (6 each side) |
| Cross-container spans/day | ~108 |
| All other spans/day (from otel-cc-connect.md) | ~540 |
| Total spans/day | ~648 |
| Daily trace data | ~130 KB |
| Tempo retention (30d) | ~4 MB |

### 10.2 Sampling Decision

**Sample 100% of cross-container traces.** The volume is negligible (< 10 traces/day). The value of having every cross-container trace is high for debugging.

For non-cross-container traces (pure message turns), follow the sampling strategy in `otel-cc-connect.md` (100% at current volume, probabilistic if scaling up).

**Sampling override mechanism:** cc-connect sets `trace-flags=01` (always sample) when creating a `cc.boss.dispatch` span. The OTel SDK's `ParentBasedSampler` ensures that if the parent is sampled, the child spans on the boss side are also sampled.

---

## 11. Troubleshooting

### Symptom: Boss spans appear orphaned (no parent trace)

**Cause**: cc-connect did not send (or boss did not receive) the `traceparent` header.

**Checklist**:
1. Verify `traceparent` header in HTTP request: `curl -v http://kyb-infra-boss:9090/api/dispatch ...` and inspect response headers.
2. Check cc-connect logs for "injecting trace context" debug line.
3. Check boss logs for "extracting trace context" debug line.
4. Verify both containers use the same OTel propagator (`propagation.TraceContext{}`).

### Symptom: Boss spans missing entirely

**Cause**: Boss OTel SDK not initialized, or boss cannot reach OTel Collector.

**Checklist**:
1. Check boss logs: `OTEL_EXPORTER_OTLP_ENDPOINT` environment variable.
2. Verify OTel Collector is reachable from boss: `curl otel-collector:4317` (gRPC) or telnet.
3. Check collector logs for incoming spans from `kyb-infra-boss` service name.

### Symptom: Tempo shows two separate traces instead of one

**Cause**: Boss created a new trace instead of continuing the parent trace. This happens if context extraction fails silently.

**Checklist**:
1. Verify boss-side extraction code uses `propagation.TraceContext{}` (not a different propagator).
2. Check if the request passes through a proxy that strips unknown headers.
3. Test with a minimal HTTP client: send `traceparent` header, verify boss creates a child span not a root.

---

## 12. Security Considerations

| Concern | Mitigation |
|---------|------------|
| **Header spoofing** | An attacker who can reach the boss API could inject arbitrary `traceparent` headers to associate their request with a legitimate trace. Since the boss API is on an internal Docker network only, the attack surface is limited to container breakout. |
| **Information leakage** | The `traceparent` header contains the TraceID and SpanID but no sensitive data (no PII, no credentials). It is safe to log. |
| **Internal network exposure** | Boss API listens on an internal Docker network only. Do not expose port 9090 to the host or externally. Use Docker network isolation (`kyb-infra` network). |
| **Injection via command** | The boss API receives shell commands. Sanitize the command parameter to prevent injection. Use parameterized commands instead of raw shell strings where possible. |

---

## 13. References

- **cc-connect OTel traces**: `docs/infra/reviews/otel-cc-connect.md`
- **MCP OTel traces**: `docs/infra/reviews/otel-mcp.md`
- **Patrol OTel traces**: `docs/infra/reviews/otel-patrol.md`
- **Boss architecture**: `docs/infra/multi-cluster-boss-architecture.md`
- **Observability overview**: `docs/infra/observability-design.md`
- **Kafka event bus**: `docs/infra/reviews/kafka-message-bus.md`
- **W3C TraceContext**: https://www.w3.org/TR/trace-context/
- **OTel HTTP propagation**: https://opentelemetry.io/docs/specs/otel/context/api-propagators/
- **Grafana Tempo service graph**: https://grafana.com/docs/tempo/latest/metrics-generator/service-graph/

---

/人◕ ‿‿ ◕人＼
