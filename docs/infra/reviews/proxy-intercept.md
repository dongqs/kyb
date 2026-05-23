---
decision: 稍后做
---

# Proxy Interception for Feishu WebSocket Traffic

**Design doc**: `docs/infra/reviews/proxy-intercept.md`
**Date**: 2026-05-23
**Scope**: MITM proxy between Feishu WebSocket and cc-connect for capture, logging, replay

---

## 1. Motivation

cc-connect logs structured key=value lines to stdout, but these are **summary snapshots** — they
contain aggregated fields (content_len, turn_duration, tokens) but never the **raw WebSocket frames**
exchanged with feishu. This means:

| Gap | Impact |
|-----|--------|
| No raw message payload | Cannot debug feishu message parsing issues |
| No frame-level timing | Cannot measure feishu WS latency separately from Claude latency |
| No replay capability | Must talk to real feishu to reproduce issues; no offline testing |
| No protocol error visibility | Feishu protocol errors (bad frames, reconnects, heartbeat failures) are invisible |
| No regression test data | Cannot build a test suite from real traffic patterns |

A MITM proxy between feishu WS and cc-connect fills all of these gaps.

---

## 2. Current Architecture

```
Feishu (open.feishu.cn)
    │
    │ WSS (wss://msg-frontier.feishu.cn:443)
    │ TLS 1.3
    ▼
cc-connect  (Go binary, WebSocket client)
    │
    ├──→ stdout: structured key=value logs (via slog)
    │             "message received" / "turn complete" / etc.
    │
    └──→ Claude API (outbound HTTPS)
```

cc-connect connects as a WebSocket **client** to feishu's msg-frontier endpoint. It:
1. Opens a single persistent WSS connection
2. Receives `im.message.receive_v1` events pushed by feishu
3. Sends acknowledgment frames
4. Sends messages back via feishu REST API (separate HTTPS, not WS)

The WS connection is **opaque** — cc-connect does not dump raw frames anywhere.

---

## 3. Design Goals

1. **Capture** — every WS frame in both directions, with nanosecond timing
2. **Log** — structured, queryable storage in ClickHouse + rotatable file dump
3. **Replay** — offline replay of captured frames to cc-connect for testing
4. **Zero impact on production** — proxy must never block or delay forwarding
5. **Fail-open** — if proxy crashes, cc-connect can reconnect directly (bypass mode)

---

## 4. Architecture

### 4.1 Overview

```
cc-connect container (single Docker container)
    │
    │ WS (ws://127.0.0.1:9443)
    │ plaintext, no TLS (loopback)
    ▼
feishu-proxy  (sidecar or co-located binary)
    │
    │ WSS (wss://msg-frontier.feishu.cn:443)
    │ TLS 1.3, proper certificate verification
    ▼
Feishu (msg-frontier.feishu.cn)
```

Two deployment options:

**Option A: Sidecar container (recommended)**
```
┌──────────────────────────────────┐
│  Docker host                     │
│                                  │
│  ┌──────────┐    ┌─────────────┐ │
│  │ cc-connect│    │ feishu-proxy│ │
│  │ :9443 ◄──┼────┼──► :9443    │ │
│  └──────────┘    └──────┬──────┘ │
│                         │        │
│                  ┌──────▼──────┐ │
│                  │  Vector     │ │
│                  │  (stdout)   │ │
│                  └─────────────┘ │
└──────────────────────────────────┘
```

cc-connect connects to `ws://feishu-proxy:9443` (Docker DNS). Proxy connects to
real feishu endpoint and streams frames bidirectionally.

**Option B: Process injection (simpler, fewer moving parts)**
```
┌──────────────────────────────────┐
│  cc-connect container            │
│                                  │
│  ┌──────────┐    ┌─────────────┐ │
│  │ cc-connect│◄───► feishu-proxy│ │
│  └──────────┘    │  (subprocess)│ │
│                  └──────┬──────┘ │
│                         │ WSS    │
└─────────────────────────┼────────┘
                          │
                   msg-frontier.feishu.cn
```

feishu-proxy runs as a subprocess managed by the same supervisor that manages
cc-connect (e.g., the Docker entrypoint script or a lightweight process manager).

**Recommendation**: Option B for simplicity. A single container, no inter-container
networking. feishu-proxy is a static Go binary (~5 MB). Both cc-connect and proxy
share the same restart policy.

### 4.2 Connection Flow

```
1. feishu-proxy starts, opens WSS to msg-frontier.feishu.cn:443
        │
2. cc-connect connects WS to 127.0.0.1:9443
        │
3. feishu-proxy associates the two connections:
        │
   feishu ──WSS──► feishu-proxy ──WS──► cc-connect
        │
4. Every frame in both directions:
   a. Forwarded immediately to the other end (zero-copy where possible)
   b. Written to stdout as a JSON line
   c. Timestamped with monotonic clock (for latency measurement)
```

### 4.3 Fail-Open / Bypass

Two independent bypass mechanisms:

**Bypass A — DNS fallback** (quick, packet-level):
- Container runs `dnsmasq` or has `/etc/hosts` entry for `msg-frontier.feishu.cn`
- When proxy is alive: `msg-frontier.feishu.cn` resolves to `127.0.0.1`
- When proxy is dead: entry removed, cc-connect reconnects directly to real feishu

**Bypass B — configurable endpoint** (planned):
- cc-connect supports `proxy_mode = true/false` in config.toml
- When proxy is unhealthy, cc-connect falls back to direct connection
- Health check: feishu-proxy exposes `GET /health` on `127.0.0.1:9444`

---

## 5. feishu-proxy Design

### 5.1 Binary

- **Language**: Go (same as cc-connect, static binary, no runtime deps)
- **Size target**: < 10 MB
- **Entrypoint**: `feishu-proxy --upstream wss://msg-frontier.feishu.cn:443 --listen :9443`
- **Capture output**: stdout (JSON lines), optional `--capture-dir /data/capture` for rotating files

### 5.2 Frame Capture Format

Each frame is emitted as a single JSON line to stdout:

```json
{"ts":"2026-05-23T16:38:00.604123457Z","stream":"upstream","dir":"recv","opcode":"text","len":1428,"payload_truncated":true,"msg_id":"om_xxxxxxxx","frame_seq":1}
{"ts":"2026-05-23T16:38:00.604987654Z","stream":"upstream","dir":"send","opcode":"text","len":64,"payload_truncated":false,"payload":"{\"type\":\"pong\"}","frame_seq":2}
{"ts":"2026-05-23T16:38:01.123456789Z","stream":"upstream","dir":"recv","opcode":"binary","len":4096,"payload_truncated":true,"payload_sha256":"abc123...","frame_seq":3}
```

| Field | Type | Description |
|-------|------|-------------|
| `ts` | RFC3339 nanos | Monotonic timestamp (proxy's clock) |
| `stream` | string | `"upstream"` (feishu→proxy) or `"downstream"` (proxy→cc-connect) |
| `dir` | string | `"recv"` or `"send"` relative to the stream |
| `opcode` | string | `"text"`, `"binary"`, `"ping"`, `"pong"`, `"close"` |
| `len` | int | Raw frame payload length in bytes |
| `payload_truncated` | bool | True if payload exceeds configurable max (default 4096 bytes) |
| `payload` | string | Only present if not truncated and `opcode` is text/binary |
| `payload_sha256` | string | Always present (SHA-256 of full payload, even if truncated) |
| `msg_id` | string | Extracted from payload if parseable (feishu message_id) |
| `frame_seq` | int | Monotonic frame counter per proxy instance (for ordering) |

### 5.3 Payload Truncation

Feishu can send large messages (images as base64, long text). To avoid flooding storage:

| Config | Default | Rationale |
|--------|---------|-----------|
| `--max-payload-log 4096` | 4096 bytes | Covers most text messages; truncates binary blobs |
| `--always-log-sha256` | true | Always compute SHA-256 for integrity verification |
| `--capture-full /data/capture` | disabled | Optional full dump to rotating files (for deep debugging) |

Full payloads are always **forwarded** — truncation only affects what gets logged.

### 5.4 Latency Tracking

The proxy inserts a tiny marker (4 bytes) into the WS frame stream at connection
start and periodically (every 60s) to measure round-trip latency through the proxy:

```
proxy sends ping frame ──► cc-connect responds pong
                              │
proxy records round-trip latency
                              │
proxy sends ping to feishu ──► feishu responds pong
```

These latencies are logged as synthetic frames and written to ClickHouse for
Grafana dashboards.

---

## 6. Capture Pipeline

### 6.1 Log Collection

```
feishu-proxy (stdout JSON lines)
    │
    ▼ Vector (sidecar or host agent)
    │  Parse JSON, extract fields
    │
    ├──► ClickHouse (cc.ws_frames)  ← queryable, 90-day retention
    │
    └──► Rotated file (/var/log/feishu-proxy/*.json.gz)  ← full dump, 30-day retention
```

### 6.2 ClickHouse Schema

```sql
CREATE TABLE cc.ws_frames (
    ts              DateTime64(9),        -- nanosecond precision
    stream          LowCardinality(String), -- 'upstream' or 'downstream'
    direction       LowCardinality(String), -- 'recv' or 'send'
    opcode          LowCardinality(String), -- 'text', 'binary', 'ping', etc.
    frame_len       UInt32,               -- raw payload length
    payload_truncated UInt8,              -- 0/1
    payload_sha256   FixedString(64),     -- SHA-256 hex digest
    msg_id          String,               -- extracted feishu message_id (if present)
    payload         String,               -- truncated to 4096 bytes (if text/binary)
    frame_seq       UInt64,               -- monotonic per proxy instance
    conn_id         String,               -- unique connection identifier
    proxy_hostname  LowCardinality(String) -- which machine ran the proxy
) ENGINE = MergeTree
ORDER BY (toDate(ts), conn_id, frame_seq)
TTL toDate(ts) + INTERVAL 90 DAY
```

**Why nanosecond precision**: feishu-proxy timestamps frames with `clock_gettime(CLOCK_MONOTONIC)`.
Nanosecond precision enables sub-millisecond latency analysis between recv→send pairs.

**Sorting key**: `(toDate(ts), conn_id, frame_seq)` — efficient for session replay
queries (get all frames for a connection in order) and time-range queries.

### 6.3 Grafana Panels (New)

| Panel | Query | Purpose |
|-------|-------|---------|
| WS throughput | `count() / 60` by `direction` | Frames per minute received vs sent |
| Frame size distribution | `quantiles(frame_len)` by `opcode` | Detect oversized frames |
| Connection lifespan | `max(ts) - min(ts)` per `conn_id` | Detect frequent reconnects |
| Latency heatmap | Round-trip ping/pong timing | Proxy forwarding latency |
| Error frames | `count() WHERE opcode='close'` | Protocol-level errors |

### 6.4 Cost Estimate

| Item | Value |
|------|-------|
| Avg frame per message exchange | ~6 frames (recv ack, recv data, send ack, send data, ping, pong) |
| Daily message volume | ~90 exchanges (from existing estimate) |
| Daily frame volume | ~540 frames |
| Avg frame log size | ~200 bytes (truncated) |
| Daily log volume | ~108 KB |
| 90-day total | ~9.7 MB (uncompressed) |
| ClickHouse compression | ~5-8x → ~1.5 MB |
| Full capture (if enabled) | ~50 KB per message → ~4.5 MB/day → 135 MB/90d |

Even with full capture enabled, storage is negligible. The schema is designed for
correctness, not compression efficiency.

---

## 7. Replay System

### 7.1 replay-feishu Binary

A separate CLI tool that reads captured frames and replays them to a target:

```
replay-feishu [flags] <source>

Sources:
  --from-ck "SELECT * FROM cc.ws_frames WHERE conn_id='xxx' ORDER BY frame_seq"
  --from-file /var/log/feishu-proxy/capture-2026-05-23.json.gz
  --from-file /data/capture/2026-05-23/conn_xxx.bin    (full capture)

Modes:
  --mode live          Replay at original timing (default)
  --mode fast-forward  Replay at 10x speed
  --mode step          Pause before each frame, wait for Enter
  --mode burst         Send all frames as fast as possible

Target:
  --target ws://127.0.0.1:9443       (default: proxy port)
  --target ws://127.0.0.1:9444       (test instance)
```

### 7.2 Replay Use Cases

| Scenario | Command | Purpose |
|----------|---------|---------|
| Debug a specific bug | `replay-feishu --from-ck "..." --mode step` | Step through a problematic session |
| Load test | `replay-feishu --from-file all-msgs.json --mode burst --target ws://staging:9443` | Send all recorded messages to a staging cc-connect |
| Regression test | `replay-feishu --from-file known-good.json --mode live` | Verify a new cc-connect version handles old traffic |
| CI integration | `replay-feishu --from-file test-suite.json --mode burst --target ws://127.0.0.1:9443 --expect-all-sent` | Automated test in CI pipeline |

### 7.3 Session Record Format (Full Capture)

When `--capture-dir` is enabled, feishu-proxy writes a binary capture format
that preserves full payloads:

```
File: /data/capture/YYYY-MM-DD/conn_<id>.bin

Format (per frame, little-endian):
  Offset  Size  Field
  0       8     timestamp_ns (monotonic)
  8       1     direction (0=recv, 1=send)
  9       1     opcode (1=text, 2=binary, 9=ping, 10=pong, 8=close)
  10      4     payload_len (uint32)
  14      N     payload (raw bytes, N = payload_len)
```

Rotation: feishu-proxy closes the file every 100 MB or 24 hours, whichever comes first.

### 7.4 Replay Integrity

replay-feishu verifies frame integrity before sending:

1. Checks SHA-256 of payload matches the captured hash (if payload_truncated=false)
2. Validates WebSocket opcode is valid for replay (skip pings, insert synthetic pongs)
3. Reports: frames sent, frames skipped, errors, total bytes
4. Exit code: 0 if all frames sent, 1 if any errors

---

## 8. Deployment

### 8.1 Container Integration

The proxy binary ships inside the cc-connect container image:

```dockerfile
# In Dockerfile
COPY --from=feishu-proxy-build /feishu-proxy /usr/local/bin/feishu-proxy
```

Or, in kyb's entrypoint.sh:

```bash
# Start proxy in background
feishu-proxy \
  --upstream wss://msg-frontier.feishu.cn:443 \
  --listen :9443 \
  --max-payload-log 4096 \
  --capture-dir /data/capture \
  > /proc/1/fd/1 2>&1 &   # stdout goes to container logs

# Configure cc-connect to use proxy
export FEISHU_WS_URL=ws://127.0.0.1:9443

# Start cc-connect (foreground)
exec cc-connect "$@"
```

### 8.2 Vector Configuration

Add a new source in Vector config to parse feishu-proxy's JSON stdout:

```toml
[sources.feishu_proxy]
type = "docker_logs"
include_containers = ["cc-connect"]
# Only match lines from feishu-proxy
# Strategy: prefix each JSON line with "[proxy]" or use a separate log tag

[transforms.feishu_frames]
type = "remap"
inputs = ["feishu_proxy"]
source = '''
  if !exists(.message) || !includes(.message, "frame_seq") {
    abort
  }
  parsed = parse_json!(.message)
  . = parsed
'''

[sinks.feishu_clickhouse]
type = "clickhouse"
inputs = ["feishu_frames"]
endpoint = "http://clickhouse:8123"
database = "cc"
table = "ws_frames"
```

### 8.3 Startup Order

```
1. feishu-proxy starts, connects to feishu WSS (retries with backoff)
2. feishu-proxy listens on :9443 (will accept connections after upstream is connected)
3. cc-connect starts, connects to ws://127.0.0.1:9443
4. cc-connect begins receiving forwarded feishu events
```

If feishu-proxy fails to connect upstream:
- It still listens on :9443
- Returns a 502-style WS close frame to any connecting client
- Logs the failure to stdout
- Retries with exponential backoff (1s, 2s, 4s, ... max 60s)

---

## 9. Security Considerations

| Concern | Mitigation |
|---------|------------|
| **Payload contains PII** | All captured payloads are truncated to 4096 bytes by default. Full capture requires explicit `--capture-dir` flag. |
| **Replay sends live messages** | replay-feishu requires `--danger` flag to replay to a non-localhost target. Default: localhost only. |
| **TLS termination** | Proxy connects to feishu with full TLS verification (no `InsecureSkipVerify`). The WS between proxy and cc-connect is plaintext but loopback-only. |
| **Credential exposure** | Auth tokens in frames (if any) are logged — same as cc-connect's own logs. No extra risk. |
| **Vector access to WS frames** | Vector runs on same host, reads docker logs only. No network access to raw WS stream. |

---

## 10. Open Questions

| Question | Options | Decision Needed |
|----------|---------|-----------------|
| cc-connect WS endpoint configurable? | (a) Already configurable via env/config.toml (b) Need to patch cc-connect | Verify cc-connect source |
| Binary distribution | (a) Compile into cc-connect Docker image (b) Separate image (c) Include in kyb repo | Depends on cc-connect build pipeline |
| Replay tool ownership | (a) Part of kyb repo (b) Standalone repo (c) Part of cc-connect repo | Keep with proxy for now |
| Capture full payloads in production? | (a) Never (privacy) (b) Opt-in per container (c) Always truncated | Truncated by default, opt-in full |
| Correlation with cc-connect logs | (a) By timestamp window (b) By msg_id (c) By frame_seq → event link | Use msg_id as the join key |

---

## 11. Implementation Plan

### Phase 1: Core Proxy (Week 1)

- [ ] Build feishu-proxy: bidirectional WS relay + stdout JSON logging
- [ ] Build feishu-proxy: ping/pong latency tracking
- [ ] Build feishu-proxy: health endpoint (`GET /health`)
- [ ] Test: manual relay of a real feishu session

### Phase 2: Storage (Week 1-2)

- [ ] Vector config for parsing feishu-proxy stdout
- [ ] ClickHouse `cc.ws_frames` table (DDL + migration via mig25)
- [ ] Grafana panels for WS metrics
- [ ] Verify: end-to-end from proxy to Grafana

### Phase 3: Replay (Week 2)

- [ ] Build replay-feishu: CK source reader
- [ ] Build replay-feishu: file source reader (binary capture format)
- [ ] Build replay-feishu: live / fast-forward / step / burst modes
- [ ] Test: capture a session, replay it to a fresh cc-connect, verify behavior matches

### Phase 4: Production Hardening (Week 3)

- [ ] Fail-open: DNS fallback mechanism
- [ ] Fail-open: configurable endpoint in cc-connect
- [ ] Restart resilience: proxy tracks upstream reconnect state
- [ ] Performance: verify zero-copy forwarding, measure overhead (<1ms latency added)

---

## 12. Alternatives Considered

### Alternative 1: Modify cc-connect to dump frames natively

Simplest approach — add a `--dump-ws-frames` flag to cc-connect. Pros: no proxy, no
new binary. Cons: couples capture logic to cc-connect's release cycle; cannot
capture without modifying cc-connect; no replay capability.

**Rejected**: Loose coupling is more valuable than simplicity here.

### Alternative 2: tcpdump + PCAP analysis

Use `tcpdump` on the loopback interface to capture raw TCP segments, then
reassemble WSS frames. Pros: no binary needed, true transparency. Cons: TLS
encryption means only encrypted blobs are visible; WSS over TLS means the
payload is encrypted on the wire. Cannot inspect frame contents.

**Rejected**: TLS encryption renders PCAP useless for payload inspection.

### Alternative 3: eBPF / sockmap

Use eBPF to hook into the kernel TLS layer or socket buffer. Pros: zero
modification to any component. Cons: requires kernel support (5.3+ with
BPF_PROG_TYPE_SK_LOOKUP), complex to maintain, fragile across kernel updates.

**Rejected**: Too complex for the current scale (~540 frames/day).

### Alternative 4: Transparent proxy with iptables TPROXY

Redirect outbound traffic to msg-frontier.feishu.cn IPs to a local proxy via
iptables. Pros: transparent to cc-connect. Cons: IP-based redirection is fragile
(feishu may change IPs); requires NET_ADMIN capability; iptables rules are
not portable across Docker networking modes.

**Rejected**: Too fragile and requires elevated privileges.

### Alternative 5: SOCKS5 proxy

Run a SOCKS5 proxy, configure cc-connect to use it via `ALL_PROXY=socks5://127.0.0.1:1080`.
Pros: standard protocol, cc-connect likely supports it (Go's `http.ProxyFromEnvironment`).
Cons: SOCKS5 does not support TLS interception; only the CONNECT tunnel is visible,
still opaque. Same problem as tcpdump — encrypted tunnel.

**Rejected**: SOCKS5 tunnels TLS, does not terminate it.

---

## 13. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Deployment model | Option B: single container, proxy as subprocess | Simpler than sidecar; no Docker networking dependencies |
| Proxy language | Go | Static binary, same runtime as cc-connect, good WS libraries (gorilla/websocket or nhooyr.io/websocket) |
| Payload logging | Truncated to 4096 bytes by default; opt-in full capture | Privacy + storage balance; SHA-256 always available for integrity |
| Storage format | JSON lines to stdout → Vector → ClickHouse | Reuses existing pipeline; no new infrastructure; Vector already deployed |
| Replay target | ws://127.0.0.1:9443 (same port as proxy) | No config changes needed for cc-connect; replay replaces proxy in test mode |
| Fail-open | DNS fallback + health endpoint | Two independent mechanisms; DNS is instant, health endpoint enables automated orchestration |

---

> **Summary**: A MITM proxy between Feishu WS and cc-connect provides raw frame visibility,
> structured storage in ClickHouse, and offline replay capability — all with <1ms latency
> overhead and fail-open safety. Total daily storage: ~108 KB (truncated) or ~4.5 MB
> (full capture). Implementation: ~3 weeks for core + storage + replay + hardening.

> ／人◕ ‿‿ ◕人＼
