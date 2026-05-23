---
decision: 稍后做
---

# SOCKS5 Proxy Interception for Feishu WebSocket Traffic

**Design doc**: `docs/infra/reviews/socks5-intercept.md`
**Date**: 2026-05-23
**Status**: Design proposal
**Prerequisites**: `docs/infra/reviews/proxy-intercept.md` (MITM proxy design, rejected SOCKS5 in Alternative 5)

---

## 1. Motivation

The existing [`proxy-intercept.md`](proxy-intercept.md) design proposes a dedicated MITM proxy
(`feishu-proxy`) that sits between cc-connect and feishu, terminating TLS, capturing WS frames,
and forwarding bidirectionally. That design is correct and comprehensive, but it has one
operational gap: **it requires changing cc-connect's WebSocket endpoint configuration**.

The MITM proxy approach demands that cc-connect connect to `ws://127.0.0.1:9443` instead of
`wss://msg-frontier.feishu.cn:443`. This means:

| Concern | Impact |
|---------|--------|
| Configuration change | Must patch cc-connect's config or env to point at proxy |
| Proxy awareness | cc-connect knows it's behind a proxy; if proxy dies, cc-connect must know how to fall back |
| Single-purpose | The proxy only intercepts feishu WS; other outbound connections are untouched |
| Only one binary | If cc-connect makes multiple upstream connections, each needs its own proxy |

A **SOCKS5-based approach** addresses all three: cc-connect configures nothing beyond
`ALL_PROXY=socks5://127.0.0.1:1080`, and the proxy is **destination-aware** — it intercepts only
feishu traffic and passes everything else through transparently. This is the standard Unix proxy
model; every Go HTTP/WS client supports it natively via `http.ProxyFromEnvironment`.

### 1.1 Why SOCKS5 Was Rejected Before

`proxy-intercept.md` Alternative 5 rejected SOCKS5 with:

> SOCKS5 does not support TLS interception; only the CONNECT tunnel is visible, still opaque.
> Same problem as tcpdump — encrypted tunnel.

**This is correct for a naive SOCKS5 proxy.** A standard SOCKS5 proxy (like `dante-server` or
`ssh -D`) only tunnels TCP bytes — it has no application-level awareness. But a **custom SOCKS5
proxy** can be destination-aware: it recognizes connections to `msg-frontier.feishu.cn:443`,
performs TLS termination (or accepts plain WS from cc-connect), and logs WS frames before
forwarding upstream.

The rejection was not of SOCKS5 itself, but of off-the-shelf SOCKS5 implementations. A custom
SOCKS5 proxy combines the best of both worlds: **standard SOCKS5 protocol** on the client side
(no cc-connect changes beyond env vars) with **MITM interception** on the feishu side (full WS
frame visibility).

---

## 2. Architecture

### 2.1 High-Level Design

```
cc-connect container
    │
    │ ALL_PROXY=socks5://127.0.0.1:1080
    │ NO_PROXY=msg-frontier.feishu.cn  ← never set; we WANT feishu to go through proxy
    │
    │ Go net/http uses ProxyFromEnvironment:
    │   SOCKS5 CONNECT to msg-frontier.feishu.cn:443
    │       (standard SOCKS5 handshake)
    ▼
┌─────────────────────────────────────────────────┐
│              feishu-socks-proxy                  │
│  (Go binary, SOCKS5 server + feishu interceptor) │
│                                                  │
│  ┌──────────────┐    ┌────────────────────────┐  │
│  │ SOCKS5 Core  │    │  Feishu Interceptor     │  │
│  │ :1080        │───►│  (destination-aware)    │  │
│  │              │    │                         │  │
│  │ Passthrough  │    │ WS frame capture        │  │
│  │ (non-feishu) │    │ TLS termination         │  │
│  │              │    │ Frame replay            │  │
│  └──────────────┘    └───────────┬─────────────┘  │
│                                  │                 │
│                                  ▼                 │
│                           stdout JSON lines       │
└──────────────────────────────────────────────────┘
         │                          │
         │ passthrough              │ WSS with frame capture
         ▼                          ▼
    any other host           msg-frontier.feishu.cn:443
    (transparent)            (intercepted, logged, forwarded)
```

### 2.2 Connection Flow

```
1. cc-connect starts, ALL_PROXY=socks5://127.0.0.1:1080 is set
        │
2. cc-connect's Go HTTP client dials msg-frontier.feishu.cn:443
        │  Go net/http sees ALL_PROXY, opens SOCKS5 connection to proxy
        ▼
3. feishu-socks-proxy receives SOCKS5 CONNECT request:
        │  - CMD=0x01 (CONNECT)
        │  - ATYP=0x03 (domain name)
        │  - DST.ADDR=msg-frontier.feishu.cn
        │  - DST.PORT=443
        ▼
4. Proxy checks destination:
        │  msg-frontier.feishu.cn:443 → INTERCEPT mode
        │  any other host              → PASSTHROUGH mode
        ▼
5a. INTERCEPT mode:
        │  ┌──────────────────────────────────────────┐
        │  │ Proxy responds SOCKS5 success (0x00)     │
        │  │ cc-connect sends TLS ClientHello         │
        │  │ Proxy terminates TLS (MITM cert)          │
        │  │ cc-connect sends WS upgrade over plaintext│
        │  │ Proxy logs WS upgrade + all frames        │
        │  │ Proxy opens WSS to real feishu            │
        │  │ Bidirectional WS frame forwarding + logging│
        │  └──────────────────────────────────────────┘
        │
5b. PASSTHROUGH mode:
        │  ┌──────────────────────────────────────────┐
        │  │ Proxy connects to destination            │
        │  │ Zero-copy TCP forwarding                  │
        │  │ Log: connect/disconnect, bytes, timing    │
        │  └──────────────────────────────────────────┘
        │
6. On close or error, proxy logs connection summary:
        │  {"event":"conn_end","dest":"msg-frontier.feishu.cn",
        │   "duration_ms":342000,"frames_fwd":142,"frames_rev":156,
        │   "bytes_fwd":28400,"bytes_rev":31200}
```

### 2.3 Two Interception Modes for Feishu

The proxy supports two modes for the feishu-side interception:

**Mode 1: TLS MITM (default)**

```
cc-connect ──SOCKS5──► proxy ──TLS terminate──► WS capture ──WSS──► feishu
                              │                     │
                              │  CA cert: feishu-ca  │
                              │  (must be trusted by  │
                              │   cc-connect image)   │
```

- Proxy generates an on-the-fly certificate for `msg-frontier.feishu.cn` signed by a custom CA.
- The CA cert must be injected into the cc-connect container's trust store.
- cc-connect sees a valid TLS connection (from its perspective) and proceeds with WS upgrade.
- Proxy sees plaintext WS frames, logs them, re-encrypts with upstream TLS.

**Mode 2: Plain WS passthrough (simpler, requires cc-connect to support `ws://`)**

```
cc-connect ──SOCKS5──► proxy ──WS forward──► WS/WSS bridge ──WSS──► feishu
```

- cc-connect connects via SOCKS5 CONNECT to `msg-frontier.feishu.cn:80` (or a proxy-specific port).
- The proxy forwards TCP bytes but also understands WS framing.
- Since there's no TLS, the proxy sees all WS frames directly.
- The proxy establishes WSS upstream to the real feishu.
- Requires cc-connect to accept a configurable WS URL scheme.

**Recommendation**: Mode 1 (TLS MITM) is more general — it requires zero changes to cc-connect's
configuration beyond setting `ALL_PROXY`. The CA cert injection is a one-time Dockerfile change.

### 2.4 TLS MITM Certificate Management

The proxy needs a CA certificate to sign on-the-fly certs for feishu's domain.

```bash
# Generate CA cert once, bake into Docker image
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout /etc/feishu-proxy/ca.key \
  -out /etc/feishu-proxy/ca.crt \
  -subj "/CN=Feishu Proxy CA/O=kyb" \
  -addext "basicConstraints=critical,CA:TRUE"

# CA cert must be injected into OS trust store
# Dockerfile:
COPY feishu-proxy-ca.crt /usr/local/share/ca-certificates/feishu-proxy-ca.crt
RUN update-ca-certificates
```

The proxy re-generates the cert per-connection:
```
client_hello → extract SNI → check if SNI matches feishu domain →
  load or generate cert for that SNI → complete TLS handshake
```

**Cert caching**: Generated certificates are cached in memory (LRU, 100 entries). Re-use for
reconnections within the TTL (default: 24h). Prevents repeated signing operations.

---

## 3. SOCKS5 Proxy Design

### 3.1 Binary

- **Language**: Go (same as cc-connect, static binary, familiar WS libraries)
- **Size target**: < 10 MB (same as feishu-proxy from proxy-intercept.md)
- **Entrypoint**: `feishu-socks-proxy --listen :1080 --mode auto`
- **Modes**: `auto` (destination-aware intercept), `intercept-all`, `passthrough-only`

### 3.2 SOCKS5 Protocol Implementation

The proxy implements the standard SOCKS5 protocol (RFC 1928):

| Step | Direction | Bytes | Description |
|------|-----------|-------|-------------|
| 1 | Client → Proxy | `0x05 0x01 0x00` | SOCKS5, 1 auth method, no-auth |
| 2 | Proxy → Client | `0x05 0x00` | No-auth accepted |
| 3 | Client → Proxy | `0x05 0x01 0x00 0x03 0x15 0x6d...` | CONNECT to domain:port |
| 4 | Proxy → Client | `0x05 0x00 0x00 0x01 0x00...` | Success, bind address |
| 5 | Client → Proxy | `TLS ClientHello` | If feishu: intercept; else: passthrough |

**Domain name parsing**: The proxy MUST parse the domain name from the SOCKS5 CONNECT request
to determine whether to intercept.

**Supported address types**:
- `0x01` (IPv4) — compare against known feishu IP ranges
- `0x03` (domain name) — match against `msg-frontier.feishu.cn` and known aliases
- `0x04` (IPv6) — match against known feishu IPv6 ranges

**Feishu domain matching**:
```go
var feishuDomains = []string{
    "msg-frontier.feishu.cn",
    "msg-frontier.larkoffice.com",
    "open.feishu.cn",
    "open.larksuite.com",
}
```

### 3.3 Go Module Structure

```
feishu-socks-proxy/
├── main.go                    # Entrypoint, flag parsing, signal handling
├── proxy/
│   ├── server.go              # SOCKS5 listener, connection acceptance
│   ├── handshake.go           # SOCKS5 handshake (auth, CONNECT parsing)
│   └── resolver.go            # Destination classification (intercept vs passthrough)
├── intercept/
│   ├── tls.go                 # TLS termination, cert generation
│   ├── ws.go                  # WebSocket upgrade detection, frame capture
│   ├── bridge.go              # Bidirectional forwarding with capture hooks
│   └── capture.go             # Frame-to-JSON-line conversion
├── pass/
│   └── forward.go             # Zero-copy TCP passthrough for non-feishu traffic
├── capture/
│   ├── stdout.go              # JSON lines to stdout
│   ├── format.go              # Frame capture schema
│   └── file.go                # Optional rotating file capture
└── config/
    └── config.go              # CLI flags, config struct
```

### 3.4 Standard SOCKS5 Features Preserved

All standard SOCKS5 features work for non-feishu traffic:

| Feature | Support | Notes |
|---------|---------|-------|
| CONNECT (TCP tunnel) | Full | Zero-copy forwarding with `io.Copy` |
| BIND (inbound) | No | Not needed; could add if required |
| UDP ASSOCIATE | No | Feishu uses TCP-only WS; UDP not in scope |
| No-auth (0x00) | Yes | Default |
| User/pass auth (0x02) | Configurable | Optional, for non-feishu outbound filtering |
| DNS resolution | Proxy-side | Proxy resolves upstream DNS for non-feishu domains |
| IPv4, IPv6, domain | Full | Domain matching for intercept classification |

---

## 4. Frame Capture & Logging

### 4.1 Capture Format

The capture format is identical to the one specified in `proxy-intercept.md` §5.2 — every
WS frame in both directions becomes a JSON line on stdout:

```json
{"ts":"2026-05-23T16:38:00.604123457Z","stream":"upstream","dir":"recv","opcode":"text","len":1428,"payload_truncated":true,"msg_id":"om_xxxxxxxx","frame_seq":1}
{"ts":"2026-05-23T16:38:00.604987654Z","stream":"upstream","dir":"send","opcode":"text","len":64,"payload_truncated":false,"payload":"{\"type\":\"pong\"}","frame_seq":2}
```

**Why reuse the same format**: The ClickHouse schema, Vector config, and Grafana panels designed
for `feishu-proxy` work unchanged with `feishu-socks-proxy`. The only difference is the source
binary name in the logs.

Full schema reference: [`proxy-intercept.md` §5.2](proxy-intercept.md#52-frame-capture-format).

### 4.2 Additional SOCKS5-Level Logging

Beyond WS frame capture (which only applies to intercepted connections), the proxy logs all
connections at the SOCKS5 level:

**Connection-level events** (all destinations, always logged):

```json
{"ts":"...","event":"conn_start","local":"127.0.0.1:1080","remote":"10.0.0.1:54321","dest":"msg-frontier.feishu.cn:443","mode":"intercept","conn_id":"abc123"}
{"ts":"...","event":"conn_end","conn_id":"abc123","duration_ms":342000,"bytes_up":28400,"bytes_down":31200,"frames_up":142,"frames_down":156,"close_reason":"normal"}
```

| Field | Type | Description |
|-------|------|-------------|
| `event` | string | `conn_start` / `conn_end` |
| `local` | string | Proxy listen address |
| `remote` | string | Client address (cc-connect or other) |
| `dest` | string | Requested destination (`host:port`) |
| `mode` | string | `intercept` / `passthrough` |
| `conn_id` | string | UUID per connection (joins start/end) |
| `duration_ms` | int | Connection lifetime |
| `bytes_up` | int | Bytes sent to upstream |
| `bytes_down` | int | Bytes received from upstream |
| `frames_up` | int | WS frames sent upstream (intercept only) |
| `frames_down` | int | WS frames received from upstream (intercept only) |
| `close_reason` | string | `normal` / `error` / `timeout` |

**Passthrough connections** only get the connection-level events (no frame-level detail).
This is intentional: we don't want to log all outbound traffic, only feishu WS.

### 4.3 Payload Truncation & Privacy

Same policy as `proxy-intercept.md` §5.3:

| Config | Default | Rationale |
|--------|---------|-----------|
| `--max-payload-log 4096` | 4096 bytes | Covers most text messages; truncates binary blobs |
| `--always-log-sha256` | true | Integrity verification without full payload |
| `--capture-full /data/capture` | disabled | Full dump to rotating files for deep debugging |

### 4.4 Non-Feishu Traffic Logging (Minimal)

For passthrough connections, the proxy logs only:
- Connection start/end event with duration and byte counts
- Destination host and port
- Error events (connection refused, DNS failure, TLS handshake failure)

**This is NOT a full traffic audit.** It is a connectivity observability layer: knowing
every outbound connection from cc-connect, its duration, and destination enables:
- Detecting unexpected outbound connections (security)
- Measuring connection churn (stability)
- Debugging "can't reach X" issues

### 4.5 TLS Handshake Capture (Intercept Mode)

When the proxy terminates TLS for feishu connections, it logs TLS-level metadata:

```json
{"ts":"...","event":"tls_handshake","conn_id":"abc123","sni":"msg-frontier.feishu.cn","tls_version":"1.3","cipher":"TLS_AES_128_GCM_SHA256","alpn":"http/1.1","cert_serial":"ABCDEF0123456789"}
```

This enables:
- Detecting TLS version or cipher downgrades
- Verifying SNI matches expected feishu domain
- Monitoring ALPN negotiation (should be `http/1.1` for WS)

---

## 5. ClickHouse Schema

### 5.1 WS Frame Table (Same as proxy-intercept.md)

Reuse `cc.ws_frames` from `proxy-intercept.md` §6.2 — identical schema, same Vector pipeline.
The only difference is an optional `proxy_type` field to distinguish SOCKS5 from direct MITM
proxy captures:

```sql
ALTER TABLE cc.ws_frames
  ADD COLUMN proxy_type LowCardinality(String) DEFAULT 'feishu-socks-proxy';
```

### 5.2 Connection Log Table (New)

```sql
CREATE TABLE cc.proxy_connections (
    ts              DateTime64(9),        -- connection start time
    conn_id         String,               -- UUID per connection
    event           LowCardinality(String), -- 'conn_start' or 'conn_end'
    local_addr      String,               -- proxy listen address
    remote_addr     String,               -- client address
    dest_host       String,               -- requested destination host
    dest_port       UInt16,               -- requested destination port
    mode            LowCardinality(String), -- 'intercept' or 'passthrough'
    duration_ms     UInt32,               -- connection lifetime (conn_end only)
    bytes_up        UInt32,               -- bytes sent to upstream (conn_end only)
    bytes_down      UInt32,               -- bytes received from upstream (conn_end only)
    frames_up       UInt32,               -- WS frames upstream (conn_end, intercept only)
    frames_down     UInt32,               -- WS frames downstream (conn_end, intercept only)
    close_reason    LowCardinality(String) -- 'normal', 'error', 'timeout'
) ENGINE = MergeTree
ORDER BY (toDate(ts), dest_host, conn_id)
TTL toDate(ts) + INTERVAL 90 DAY
```

### 5.3 TLS Handshake Table (Intercept Mode, New)

```sql
CREATE TABLE cc.proxy_tls_handshakes (
    ts              DateTime64(9),
    conn_id         String,
    sni             String,               -- TLS SNI from ClientHello
    tls_version     LowCardinality(String), -- '1.2', '1.3'
    cipher          String,               -- negotiated cipher suite
    alpn            String,               -- negotiated ALPN protocol
    cert_serial     String,               -- served certificate serial
    success         UInt8                 -- 1=success, 0=failure
) ENGINE = MergeTree
ORDER BY (toDate(ts), conn_id)
TTL toDate(ts) + INTERVAL 90 DAY
```

### 5.4 Vector Configuration

Reuse the existing Vector pipeline from `proxy-intercept.md` §8.2, with an additional source
for connection-level logs:

```toml
# Parse SOCKS5 connection events (json lines matching "event":"conn_*")
[transforms.proxy_connections]
type = "remap"
inputs = ["feishu_proxy"]     # same docker_logs source
source = '''
  if !exists(.event) || !includes(.event, "conn_") {
    abort
  }
  parsed = parse_json!(.message)
  . = parsed
'''

[sinks.proxy_connections_ck]
type = "clickhouse"
inputs = ["proxy_connections"]
endpoint = "http://clickhouse:8123"
database = "cc"
table = "proxy_connections"
```

---

## 6. Deployment

### 6.1 Single-Container Approach (Same as proxy-intercept.md Option B)

The SOCKS5 proxy ships inside the cc-connect container image:

```dockerfile
# Dockerfile additions
COPY --from=feishu-socks-proxy-build /feishu-socks-proxy /usr/local/bin/feishu-socks-proxy
COPY feishu-proxy-ca.crt /usr/local/share/ca-certificates/feishu-proxy-ca.crt
RUN update-ca-certificates
```

In the container's entrypoint or supervisor:

```bash
# Start SOCKS5 proxy in background
feishu-socks-proxy \
  --listen :1080 \
  --mode auto \
  --max-payload-log 4096 \
  --capture-dir /data/capture \
  > /proc/1/fd/1 2>&1 &

# cc-connect will automatically use it via ALL_PROXY
export ALL_PROXY=socks5://127.0.0.1:1080
export HTTP_PROXY=socks5://127.0.0.1:1080
export HTTPS_PROXY=socks5://127.0.0.1:1080

# Start cc-connect (foreground)
exec cc-connect "$@"
```

### 6.2 Environment Variable Strategy

The proxy is transparent to cc-connect: it only needs `ALL_PROXY`. The proxy handles all
destinations:

| Destination | Proxy Behavior | Rationale |
|-------------|----------------|-----------|
| `msg-frontier.feishu.cn:443` | Intercept + capture | Primary target: WS frame logging |
| `open.feishu.cn:443` | Intercept + capture | REST API calls (can also log HTTP req/resp) |
| `open.larksuite.com:443` | Intercept + capture | International feishu |
| `api.anthropic.com:443` | Passthrough (standard SOCKS5) | Claude API — no interception needed |
| All other HTTPS | Passthrough (standard SOCKS5) | Transparent proxy |

**NO_PROXY configuration** (set on cc-connect side):
```bash
# Only exclude internal services from SOCKS5
export NO_PROXY="localhost,127.0.0.1,.internal,.local,host.docker.internal"
# Do NOT put feishu domains in NO_PROXY — that defeats the purpose
```

### 6.3 Fail-Open / Bypass

If the SOCKS5 proxy crashes, cc-connect loses ALL outbound connectivity (because ALL_PROXY
points to a dead proxy). Three mitigation layers:

**Layer 1: Supervisor auto-restart**
```bash
# Use a simple watchdog in the entrypoint
{
  while true; do
    if ! pgrep -x feishu-socks-proxy >/dev/null; then
      feishu-socks-proxy --listen :1080 --mode auto > /proc/1/fd/1 2>&1 &
    fi
    sleep 1
  done
} &
```

**Layer 2: Connection timeout fallback**
- cc-connect's Go HTTP client has a default dial timeout (30s).
- If the SOCKS5 proxy is unreachable, the connection will timeout and cc-connect will retry.
- With the supervisor restart, the proxy should be back within 1-2 seconds.
- Total impact: ~31 seconds of failed outbound connections.

**Layer 3: ALL_PROXY bypass via health check (advanced)**
- feishu-socks-proxy exposes `GET /health` on a control port (e.g., `127.0.0.1:1081`).
- A separate health-check script monitors the control port.
- If the proxy is unhealthy for >5s, the script **clears ALL_PROXY** from cc-connect's
  environment and sends SIGUSR1 to force cc-connect to reload configuration.
- When the proxy recovers, ALL_PROXY is restored.

### 6.4 Startup Order

```
1. feishu-socks-proxy starts, listens on :1080
2. cc-connect starts (ALL_PROXY already set)
3. cc-connect's Go HTTP client connects through SOCKS5 proxy automatically
4. Proxy intercepts feishu WS, passes through everything else
```

No explicit ordering needed. If cc-connect starts before the proxy, Go's HTTP client will
retry the SOCKS5 connection with exponential backoff (default Go behavior).

---

## 7. Comparison: SOCKS5 Proxy vs. Dedicated MITM Proxy

| Aspect | feishu-socks-proxy (this design) | feishu-proxy (proxy-intercept.md) |
|--------|----------------------------------|-----------------------------------|
| **cc-connect config change** | None (just env vars) | Must change WS endpoint from `wss://feishu` to `ws://proxy:9443` |
| **Protocol** | SOCKS5 (RFC 1928) | Custom WS relay |
| **Non-feishu traffic** | Standard SOCKS5 passthrough | Not handled (separate proxy needed) |
| **TLS termination** | MITM at SOCKS5 layer | Accepts plain WS from cc-connect |
| **CA cert required** | Yes (injected into container) | No (plain WS loopback) |
| **WS frame capture** | Same capture format + schema | Same capture format + schema |
| **Connection-level logging** | All connections (feishu + non-feishu) | Only feishu WS |
| **Code complexity** | Higher (SOCKS5 impl + WS capture) | Lower (WS relay only) |
| **Binary size** | ~8 MB (SOCKS5 + capture) | ~5 MB (capture only) |
| **Standard compliance** | Implements RFC 1928 | Custom protocol |
| **Off-the-shelf replacement** | Can swap with `dante-server` (passthrough only) | No replacement |
| **Replay tool** | Works identically (same capture format) | Works identically |
| **Vector pipeline** | Same + new connection table | Same |
| **Grafana dashboards** | Same WS panels + new connection panels | Same WS panels |

### 7.1 When to Choose Which

**Choose feishu-socks-proxy (SOCKS5) when:**
- cc-connect cannot be easily reconfigured (no WS endpoint config)
- You want observability over ALL outbound connections, not just feishu WS
- You want to use standard Unix proxy conventions (ALL_PROXY, NO_PROXY)
- Multiple services in the container need proxy support

**Choose feishu-proxy (MITM relay) when:**
- You want the simplest possible deployment (no CA cert, no MITM complexity)
- cc-connect's WS endpoint is configurable
- You only care about feishu WS traffic
- You want zero impact on non-feishu traffic even during proxy development

### 7.2 Recommended Approach

**Start with feishu-proxy (MITM relay)** — it's simpler, has no CA cert dependency, and
addresses the core problem (WS frame capture). Then **migrate to feishu-socks-proxy** when
you need:

1. Transparency (no cc-connect config change)
2. Full outbound connection observability
3. Standard SOCKS5 protocol compatibility

The two proxies can coexist: feishu-socks-proxy handles the SOCKS5 layer and delegates feishu
interception to feishu-proxy as a backend. Or, more practically, feishu-socks-proxy incorporates
feishu-proxy's capture logic natively (which is what this design does).

---

## 8. SOCKS5-Specific Grafana Panels

Beyond the WS frame panels from `proxy-intercept.md` §6.3, the SOCKS5 proxy enables:

### 8.1 Connection Volume

```
┌─────────────────────────────────────────────────────────┐
│ Outbound Connections — Last 1h                          │
│                                                         │
│  ████████████████  feishu WS (intercept)     = 24 conns │
│  ██████████         api.anthropic.com (pass)  = 16 conns │
│  ████               docker.io (pass)          =  6 conns │
│  ██                 other (pass)              =  3 conns │
│                                                         │
│  Total: 49 connections                                  │
└─────────────────────────────────────────────────────────┘
```

### 8.2 Connection Duration Distribution

```
┌─────────────────────────────────────────────────────────┐
│ Connection Duration — feishu WS only                    │
│                                                         │
│  <1s    ████  4 connections  (reconnect spikes)         │
│  1-60s  ██    2 connections                              │
│  1-5m   ██████                                           │
│  5-30m  ███████████████████  persistent WS sess         │
│  >30m   ████████████████████████████████████ 24 conns   │
└─────────────────────────────────────────────────────────┘
```

### 8.3 Passthrough Destination Heatmap

```
┌─────────────────────────────────────────────────────────┐
│ Top Passthrough Destinations — Last 24h                 │
│                                                         │
│  api.anthropic.com        ████████████████  142 conns   │
│  docker.xuanyuan.me       ██████             52 conns   │
│  git.leyantech.com        █████             48 conns    │
│  registry.npmjs.org       ████              32 conns    │
│  pypi.org                 ██                18 conns    │
└─────────────────────────────────────────────────────────┘
```

### 8.4 TLS Handshake Summary

```
┌─────────────────────────────────────────────────────────┐
│ TLS Handshake Health — feishu WS                        │
│                                                         │
│  TLS 1.3:  100%   Cipher: TLS_AES_128_GCM_SHA256       │
│  ALPN:     http/1.1 (100%)                              │
│  Handshake failures: 0 in last 24h                      │
│  Certificate expiry: 345 days remaining                 │
└─────────────────────────────────────────────────────────┘
```

---

## 9. Security Considerations

| Concern | Mitigation |
|---------|------------|
| **MITM CA private key exposure** | CA key is generated at build time, stored in container image. If the image is compromised, the CA key is compromised. Mitigation: use a separate CA per deployment; rotate keys; revoke by removing from trust store. |
| **MITM cert for wrong domain** | Proxy only generates certs for feishu domains (whitelist). Any request for a non-feishu domain in intercept mode triggers a warning log and fallback to passthrough. |
| **SOCKS5 proxy as open relay** | Proxy binds to `127.0.0.1` by default. If exposed to network, implement user/pass auth for non-feishu destinations. |
| **PII in captured frames** | Same policy as proxy-intercept.md: truncated to 4096 bytes by default, full capture requires explicit `--capture-dir` flag. |
| **Replay sends live messages** | replay-feishu tool (from proxy-intercept.md) requires `--danger` flag for non-localhost targets. |
| **All traffic goes through proxy** | If proxy crashes, all outbound traffic stops (fail-closed). Mitigated by supervisor restart + health check bypass (Layer 3 in §6.3). |
| **Go crypto/tls compliance** | Go's crypto/tls library supports TLS 1.3, proper certificate verification, and secure cipher suites. No custom crypto code. |

### 9.1 MITM Trust Model

```
┌─────────────┐     MITM TLS      ┌──────────────────┐     Real TLS     ┌──────────┐
│ cc-connect  │ ◄──────────────► │ feishu-socks-proxy│ ◄────────────► │ feishu   │
│             │    trusts CA.crt  │                   │   verifies      │          │
│             │                   │                   │   real feishu   │          │
│             │                   │                   │   certificate   │          │
└─────────────┘                   └──────────────────┘                 └──────────┘
```

- cc-connect trusts the proxy's CA cert (injected into OS trust store).
- The proxy verifies feishu's real certificate (no `InsecureSkipVerify`).
- If feishu's cert is invalid, the proxy **fails closed**: it closes the connection and logs
  the error. No insecure fallback.

---

## 10. Open Questions

| Question | Options | Decision Needed |
|----------|---------|-----------------|
| MITM vs plain WS intercept | (a) MITM (TLS terminate, no cc-connect change) (b) Plain WS (requires cc-connect to support ws://) | MITM is more general; plain WS avoids CA complexity |
| CA cert distribution | (a) Bake into Docker image (b) Generate at container startup (c) Mount as secret | Baking is simplest; startup generation is more secure |
| Non-feishu intercept | (a) Passthrough only (b) Log connection metadata only (c) Full capture for all traffic | (b) is the sweet spot: metadata for observability, no payload for non-feishu |
| Proxy restart on ALL_PROXY | (a) Supervisor auto-restart only (b) + health-check clears ALL_PROXY (c) + DNS-based bypass | Start with (a), implement (b) for production hardening |
| SOCKS5 auth for non-feishu | (a) No auth (loopback, trust) (b) User/pass for non-localhost | No auth for now; add if proxy is exposed beyond localhost |

---

## 11. Implementation Plan

### Phase 1: Core SOCKS5 Proxy (Week 1)

- [ ] Implement SOCKS5 handshake (auth-neg, CONNECT parsing, domain/IPv4/IPv6 ATYP)
- [ ] Implement passthrough mode: zero-copy TCP forwarding via `io.Copy`
- [ ] Implement destination classification (feishu domain whitelist)
- [ ] Implement connection-level logging (conn_start / conn_end events)
- [ ] Test: standard SOCKS5 passthrough for non-feishu traffic (`curl -x socks5://...`)

### Phase 2: Feishu Interception (Week 1-2)

- [ ] Implement TLS MITM: on-the-fly cert generation, Go crypto/tls server
- [ ] Implement WS upgrade detection (parse HTTP upgrade request from decrypted stream)
- [ ] Implement WS frame capture (adopt capture logic from feishu-proxy design)
- [ ] Implement bidirectional WS forwarding with capture hooks
- [ ] Test: capture a real feishu session end-to-end

### Phase 3: Observability Pipeline (Week 2)

- [ ] Implement stdout JSON line output for WS frames
- [ ] Implement connection log output
- [ ] Implement TLS handshake log output
- [ ] Vector config: parse new JSON sources, route to ClickHouse
- [ ] Create `cc.proxy_connections` and `cc.proxy_tls_handshakes` tables
- [ ] Grafana panels: connection volume, duration distribution, passthrough destinations

### Phase 4: Production Hardening (Week 3)

- [ ] CA cert generation + injection into container build
- [ ] Supervisor watchdog for proxy crash recovery
- [ ] Health check endpoint (`GET /health` on control port)
- [ ] ALL_PROXY bypass on sustained proxy failure
- [ ] Performance benchmark: latency overhead of MITM vs passthrough
- [ ] Fail-safe: proxy rejects non-whitelist domains in intercept mode

---

## 12. Async Integration with Feishu Delivery Tracking

The SOCKS5 proxy is complementary to the feishu delivery monitoring system
([`feishu-delivery.md`](feishu-delivery.md)). Where delivery tracking provides high-level
state machine observability (QUEUED → SENT → DELIVERED → READ), the SOCKS5 proxy provides
low-level frame capture:

```
SOCKS5 Proxy:                          Delivery Tracker:
  "when did the WS frame arrive?"        "did the message reach the user?"
  "what was in the frame payload?"       "was it read?"
  "how long did the WS round-trip take?" "was it silently dropped?"
  "did the WS connection drop?"          "should we alert?"

Integration point: msg_id
  WS frame msg_id ──join──► delivery_tracking.message_id
```

The two systems share the same `msg_id` as the correlation key. A Grafana dashboard can
join `cc.ws_frames` (from SOCKS5 proxy) with `infra.delivery_events` (from delivery tracker)
to create a unified view:

```
Trace for om_abc123:
  ⏱ 14:30:00.000  SOCKS5: WS frame received (msg_id=om_abc123)
  ⏱ 14:30:00.050  SOCKS5: WS frame forwarded to cc-connect
  ⏱ 14:30:00.100  Delivery: QUEUED → SENDING
  ⏱ 14:30:00.500  Delivery: SENDING → SENT (message_id=om_abc123)
  ⏱ 14:30:01.200  SOCKS5: WS frame sent to feishu (ack/response)
  ⏱ 14:30:01.300  Delivery: SENT → DELIVERED
  ⏱ 14:30:30.000  Delivery: Read receipt received (READ)
```

This unified trace enables answering questions like:
- "Did the message arrive at cc-connect?" → Check SOCKS5 WS frame log
- "Did cc-connect process it?" → Check delivery state machine
- "Did feishu deliver it to the user?" → Check delivery DELIVERED state
- "Did the user read it?" → Check delivery READ state

---

## 13. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Interception method | TLS MITM (default) | Zero cc-connect config changes; works with any WS client that trusts the CA |
| SOCKS5 auth | No-auth (loopback) | Proxy binds to 127.0.0.1; no auth needed for loopback traffic |
| Non-feishu handling | Passthrough + connection metadata | Observability without payload inspection overhead |
| CA cert distribution | Bake into container image | Simplest deployment; rotation handled by image rebuild |
| Capture format | Reuse `proxy-intercept.md` format | Same ClickHouse schema, Vector config, Grafana panels |
| Fail-open strategy | Supervisor restart + health check bypass | Three-layer: auto-restart (1s), health check (5s), ALL_PROXY clear (last resort) |

---

## 14. Summary

The SOCKS5 proxy approach reopens a previously rejected alternative by addressing its core
limitation: instead of using an off-the-shelf SOCKS5 proxy that only tunnels opaque TLS, use
a **custom destination-aware SOCKS5 proxy** that:

1. Implements standard SOCKS5 (RFC 1928) — no proprietary protocol, works with any Go/Rust/Node
   HTTP client that supports `ALL_PROXY`.
2. Intercepts feishu WS connections via TLS MITM — full frame visibility, same capture format
   as the dedicated MITM proxy design.
3. Passes through non-feishu traffic — zero-copy TCP forwarding with connection-level logging.
4. Requires zero cc-connect configuration changes — just set `ALL_PROXY` and inject the CA cert.

**Compared to the dedicated MITM proxy** (`feishu-proxy` from `proxy-intercept.md`):

| When to choose | Recommendation |
|----------------|----------------|
| Simplest deployment, cc-connect WS endpoint is configurable | `feishu-proxy` (MITM relay) |
| Full outbound observability, zero cc-connect changes | `feishu-socks-proxy` (SOCKS5) |
| Both can coexist; SOCKS5 proxy delegates feishu capture | Build SOCKS5 proxy with internal capture logic |

**Implementation effort**: ~3 weeks (same as feishu-proxy) for core SOCKS5 + feishu interception
+ observability pipeline + hardening. The SOCKS5 implementation adds ~1 week over the pure
MITM proxy due to RFC 1928 compliance, destination classification, and passthrough forwarding.

---

> **Summary**: A custom destination-aware SOCKS5 proxy provides WS frame capture and full
> outbound connection observability with zero cc-connect configuration changes. TLS MITM at
> the SOCKS5 layer enables the same frame-level visibility as a dedicated WS MITM proxy,
> while also providing standard SOCKS5 passthrough for all other traffic. The two approaches
> share capture format, storage schema, and Grafana dashboards — making the choice a matter
> of deployment preference rather than technical capability.

> ／人◕ ‿‿ ◕人＼
