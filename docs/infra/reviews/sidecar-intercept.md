---
decision: 稍后做
---

# Sidecar Intercept: Capturing Feishu WS Traffic from cc-connect

**Design doc**: `docs/infra/reviews/sidecar-intercept.md`
**Date**: 2026-05-23
**Scope**: Sidecar container that runs alongside cc-connect, intercepting all Feishu WebSocket traffic, logging structured frames to ClickHouse.
**Prerequisites**: `proxy-intercept.md` (MITM proxy design), `sidecar-pattern.md` (general sidecar pattern), `cc-ws-health.md` (WS health monitoring)

---

## 1. Problem

cc-connect's Feishu WebSocket connection is opaque. The `proxy-intercept.md` design solves this with a **process-injection** approach (feishu-proxy binary co-located in the same container). However, that approach has operational limitations:

| Issue | Impact |
|-------|--------|
| **Coupled lifecycle** | Proxy restarts with cc-connect; cannot update independently |
| **Shared resource constraints** | Proxy competes for CPU/memory with cc-connect |
| **Single-container image** | Requires rebuilding cc-connect image to update proxy |
| **No independent health signal** | Cannot tell if proxy is healthy independently of cc-connect |
| **Rollback risk** | Proxy bug requires rolling back cc-connect too |

A **sidecar container** decouples these concerns: the capture proxy lives in its own container, sharing cc-connect's network namespace, with independent lifecycle, resource limits, and update cadence.

---

## 2. Architecture

### 2.1 High-Level

```
┌─────────────────────────────────────────────────────────┐
│  Docker Host                                              │
│                                                           │
│  ┌───────────────────────┐                               │
│  │  cc-connect            │  --network container:cc-conn │
│  │  (Go WS client)        │  (shared netns)              │
│  │                        │                               │
│  │  ws://127.0.0.1:9443   │◄────┐                        │
│  └────────────────────────┘     │                        │
│                                  │                        │
│  ┌───────────────────────────────┴──┐                    │
│  │  feishu-ws-cap (sidecar)          │                    │
│  │                                   │                    │
│  │  ┌────────────────────────────┐  │                    │
│  │  │  WS Proxy Core             │  │                    │
│  │  │  listen :9443              │  │                    │
│  │  │  upstream: msg-frontier    │  │                    │
│  │  │  .feishu.cn:443            │  │                    │
│  │  └───────────┬────────────────┘  │                    │
│  │              │ stdout            │                    │
│  │              ▼                   │                    │
│  │  ┌────────────────────────────┐  │                    │
│  │  │  JSON Frame Logger         │  │                    │
│  │  │  (JSON lines → stdout)     │  │                    │
│  │  └────────────────────────────┘  │                    │
│  │                                   │                    │
│  │  ┌────────────────────────────┐  │                    │
│  │  │  Health Endpoint :9444     │  │                    │
│  │  │  GET /health, GET /status  │  │                    │
│  │  └────────────────────────────┘  │                    │
│  └───────────────────────────────────┘                    │
│                                     │                     │
│                          Vector (host or daemon)          │
│                          reads sidecar stdout             │
│                                     │                     │
│                                     ▼                     │
│                          ClickHouse cc.ws_frames          │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Network Model

The sidecar uses `--network container:cc-connect` (shared network namespace):

```bash
docker run -d \
  --name feishu-ws-cap \
  --network container:kyb-infra-cc-connect \
  feishu-ws-cap:latest
```

This means:
- Both containers share the same network stack (same `127.0.0.1`, same interfaces)
- cc-connect connects to `ws://127.0.0.1:9443` which is the sidecar's listener
- The sidecar connects outbound to `wss://msg-frontier.feishu.cn:443` using cc-connect's network
- No port publishing needed (loopback only — security by design)

### 2.3 Connection Flow

```
1. Sidecar starts, listens on :9443 (loopback)
2. Sidecar opens upstream WSS to msg-frontier.feishu.cn:443
3. cc-connect connects WS to ws://127.0.0.1:9443
4. Sidecar associates upstream ↔ downstream
5. Every frame:
   a. Forwarded immediately (zero-copy path)
   b. Emitted as JSON line to stdout
   c. Timestamped with monotonic clock
```

The sidecar **must** establish the upstream connection before accepting downstream connections. If upstream connect fails, the sidecar returns a 502-style WS close frame to downstream clients and retries with backoff.

### 2.4 Startup Order

```
t=0   Sidecar starts
      → Connect upstream WSS (retry with 1s, 2s, 4s, max 60s backoff)
      → Listen on :9443

t=+X  cc-connect starts (or is already running)
      → Connect WS to 127.0.0.1:9443
      → Sidecar associates, frames flow

t=+Y  Vector catches sidecar stdout
      → Parse JSON lines
      → Write to ClickHouse cc.ws_frames
```

Because the sidecar retries upstream indefinitely, the startup order is flexible:
- Sidecar can start before cc-connect (upstream connects first, waits for downstream)
- Sidecar can start after cc-connect (cc-connect's WS connection will fail, cc-connect retries)
- If sidecar restarts mid-session, cc-connect's WS client will detect the close and reconnect

---

## 3. Sidecar Specification

### 3.1 Container Image

| Property | Value |
|----------|-------|
| **Base image** | `golang:1.23-alpine` (build) → `alpine:3.21` (runtime, ~5 MB) |
| **Binary** | Static Go binary (`feishu-ws-cap`), single-file, no libc deps |
| **Image size** | Target < 10 MB (scratch-based) |
| **Entrypoint** | `/feishu-ws-cap --upstream wss://msg-frontier.feishu.cn:443 --listen :9443` |
| **User** | `nobody:nobody` (no root needed) |
| **Capabilities** | None (no NET_ADMIN, no SYS_PTRACE) |

### 3.2 Resource Limits

| Resource | Request | Limit | Rationale |
|----------|---------|-------|-----------|
| CPU | 0.1 core | 0.5 core | Low-throughput proxy (~540 frames/day) |
| Memory | 16 MB | 64 MB | Static binary, small buffers |
| Disk | 0 | 0 | No persistent storage (logs to stdout) |

### 3.3 Process Model

Single-threaded Go binary using `gorilla/websocket` or `nhooyr.io/websocket` with:

- **One goroutine** for upstream read → downstream write
- **One goroutine** for downstream read → upstream write
- **One goroutine** for health endpoint (HTTP on :9444)
- **Periodic ping/pong** on both directions (30s interval)
- No external dependencies (no database, no filesystem writes)

### 3.4 Command-Line Flags

```
feishu-ws-cap \
  --upstream wss://msg-frontier.feishu.cn:443 \
  --listen :9443 \
  --health :9444 \
  --max-payload-log 4096 \
  --always-log-sha256 \
  --ping-interval 30s
```

| Flag | Default | Description |
|------|---------|-------------|
| `--upstream` | `wss://msg-frontier.feishu.cn:443` | Upstream Feishu WSS endpoint |
| `--listen` | `:9443` | Downstream WS listen address |
| `--health` | `:9444` | Health HTTP endpoint address |
| `--max-payload-log` | `4096` | Max payload bytes to log (0 = log all) |
| `--always-log-sha256` | `true` | Always compute and log SHA-256 of payload |
| `--ping-interval` | `30s` | WS ping interval |

---

## 4. Frame Capture Format

### 4.1 JSON Line Output

Each frame is emitted as a single JSON line to stdout. The format is identical to `proxy-intercept.md` Section 5.2 for compatibility:

```json
{"ts":"2026-05-23T16:38:00.604123457Z","stream":"upstream","dir":"recv","opcode":"text","len":1428,"payload_truncated":true,"msg_id":"om_xxxxxxxx","frame_seq":1,"sidecar":"feishu-ws-cap"}
{"ts":"2026-05-23T16:38:00.604987654Z","stream":"upstream","dir":"send","opcode":"text","len":64,"payload_truncated":false,"payload":"{\"type\":\"pong\"}","frame_seq":2,"sidecar":"feishu-ws-cap"}
```

**Additional field**: `"sidecar":"feishu-ws-cap"` — distinguishes sidecar capture from other sources.

### 4.2 Stream Labels

| `stream` value | Direction | Meaning |
|----------------|-----------|---------|
| `"upstream"` | Feishu ↔ sidecar | The WSS connection to msg-frontier |
| `"downstream"` | Sidecar ↔ cc-connect | The WS connection to cc-connect |

For mode == passthrough (no MITM), only `"upstream"` is used (single logical stream).

### 4.3 Output Rate

At ~90 messages/day and ~6 frames per message:
- **Average**: ~540 frames/day ≈ 0.006 frames/second
- **Peak** (burst during reconnect): ~20 frames in 1 second
- **Stdout volume**: ~108 KB/day (truncated payloads)

These rates are negligible. Even at 100x growth, stdout at 10 MB/day is well within Docker's log driver capacity.

---

## 5. ClickHouse Schema

The schema is identical to `proxy-intercept.md` Section 6.2 (`cc.ws_frames`), with one additional column for sidecar identification:

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
    proxy_hostname  LowCardinality(String), -- which machine ran the proxy
    sidecar         LowCardinality(String) DEFAULT 'feishu-ws-cap',  -- NEW: capture source
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(ts), conn_id, frame_seq)
TTL toDate(ts) + INTERVAL 90 DAY
```

The `sidecar` column enables filtering Grafana panels by capture source, or correlating multiple sidecar instances across clusters.

### 5.1 Migration Note

If `cc.ws_frames` already exists (from `proxy-intercept.md` deployment), add the column:

```sql
ALTER TABLE cc.ws_frames ADD COLUMN IF NOT EXISTS sidecar LowCardinality(String) DEFAULT 'feishu-ws-cap';
```

---

## 6. Deployment

### 6.1 Docker Compose (Preferred)

```yaml
services:
  cc-connect:
    image: cc-connect:latest
    networks: [kyb-net]
    environment:
      FEISHU_WS_URL: "ws://127.0.0.1:9443"  # ← point to sidecar
    # ... rest of cc-connect config ...

  feishu-ws-cap:
    image: feishu-ws-cap:latest
    network_mode: "service:cc-connect"   # ← shared network namespace
    environment:
      RUST_LOG: "info"                   # if Go, GLOG or equivalent
    command:
      - --upstream=wss://msg-frontier.feishu.cn:443
      - --listen=:9443
      - --health=:9444
      - --max-payload-log=4096
    depends_on: []
    # No port mappings needed (all loopback within shared netns)
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:9444/health"]
      interval: 15s
      timeout: 5s
      retries: 3
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

### 6.2 Docker Run (Ad-hoc)

```bash
# Step 1: Find or start cc-connect
docker run -d --name kyb-infra-cc-connect ... cc-connect:latest

# Step 2: Attach sidecar (shared network namespace)
docker run -d \
  --name kyb-infra-feishu-ws-cap \
  --network container:kyb-infra-cc-connect \
  --restart unless-stopped \
  --health-cmd "wget -qO- http://127.0.0.1:9444/health" \
  --health-interval 15s \
  --health-retries 3 \
  feishu-ws-cap:latest \
  --upstream wss://msg-frontier.feishu.cn:443 \
  --listen :9443 \
  --health :9444

# Step 3: Configure cc-connect to use the sidecar
# If cc-connect supports --feishu-ws-url flag or env var
docker exec kyb-infra-cc-connect \
  sh -c 'echo "FEISHU_WS_URL=ws://127.0.0.1:9443" >> /etc/environment'
# Or restart cc-connect with env var
```

### 6.3 Vector Configuration

Vector runs as a host-level daemon (or per-service sidecar, see `sidecar-pattern.md`) and reads the sidecar's Docker logs:

```toml
# vector/feishu-ws-cap.toml
[sources.feishu_cap_logs]
type = "docker_logs"
include_containers = ["kyb-infra-feishu-ws-cap"]

[transforms.parse_frames]
type = "remap"
inputs = ["feishu_cap_logs"]
source = '''
  # Only process JSON lines that look like frame records
  if !exists(.message) || !includes(.message, "frame_seq") {
    abort
  }
  parsed = parse_json!(.message)
  . = parsed
  # Add agent metadata
  ._ingested_at = now()
'''

[sinks.feishu_ck]
type = "clickhouse"
inputs = ["parse_frames"]
endpoint = "${CK_ENDPOINT}"
database = "cc"
table = "ws_frames"
encoding.id = "json"
```

---

## 7. Fail-Open and Bypass

### 7.1 Sidecar Health

The sidecar exposes two health endpoints on `:9444`:

| Endpoint | Response | Purpose |
|----------|----------|---------|
| `GET /health` | `200 OK` (always alive) | Docker healthcheck |
| `GET /status` | `{"upstream":"connected","downstream":"connected","frames_logged":1234,"uptime_seconds":3600}` | Detailed status |

### 7.2 Bypass Mode

If the sidecar is unhealthy or absent:

**Option A: DNS-based bypass** (zero config change to cc-connect)
- Sidecar runs dnsmasq or adds `/etc/hosts` entry mapping `msg-frontier.feishu.cn` to `127.0.0.1`
- When sidecar is down, remove the entry → cc-connect resolves to real Feishu IP
- Requires shared `/etc/hosts` or DNS container in the same network

**Option B: Configurable endpoint** (requires cc-connect support)
- cc-connect checks `GET http://127.0.0.1:9444/health` before connecting
- If sidecar unhealthy → cc-connect connects directly to `wss://msg-frontier.feishu.cn:443`
- If sidecar recovers → cc-connect can be signaled to reconnect through sidecar

**Option C: Manual bypass** (operator action)
```bash
# Stop sidecar, configure cc-connect to bypass
docker stop kyb-infra-feishu-ws-cap
docker exec kyb-infra-cc-connect \
  sh -c 'export FEISHU_WS_URL=wss://msg-frontier.feishu.cn:443 && exec cc-connect'
```

### 7.3 Graceful Degradation

| Scenario | Behavior | Data Loss |
|----------|----------|-----------|
| Sidecar container crash | cc-connect WS connection breaks; cc-connect reconnects immediately (bypass or wait for sidecar restart) | Frames during crash window lost |
| Sidecar restart (planned) | Graceful shutdown: send WS close to downstream, upstream close. cc-connect reconnects on restart. | Frames during ~1s restart lost |
| cc-connect restart | Sidecar upstream connection remains; waits for downstream reconnect | No loss (frames buffered in stdout, flushed on restart) |
| Vector outage | Sidecar stdout accumulates in Docker log driver (up to configured max-size/max-file) | No loss until log rotation |
| ClickHouse outage | Vector buffers up to 100 MB on disk (or configured buffer size) | No loss for typical outage duration |

---

## 8. Sidecar Lifecycle Management

### 8.1 Update Procedure

```bash
# 1. Pull new image
docker pull ghcr.io/kyb/feishu-ws-cap:latest

# 2. Recreate sidecar (brief WS interruption)
docker rm -f kyb-infra-feishu-ws-cap
docker run -d ... feishu-ws-cap:latest ...

# 3. cc-connect auto-reconnects to the new sidecar
```

Because the sidecar is independent, updates do not require cc-connect restart:
- Old sidecar stops → cc-connect's WS detects close → cc-connect reconnects
- New sidecar starts, listens on :9443, upstream connects
- cc-connect's retry loop connects to new sidecar
- Total downtime: ~2-3 seconds (cc-connect reconnect timeout)

### 8.2 Sidecar Watch Script

For environments without Docker Compose, a watchdog ensures the sidecar is always present:

```bash
# infr a/observability/sidecar-watch.sh
SIDECAR_NAME="kyb-infra-feishu-ws-cap"
TARGET_NAME="kyb-infra-cc-connect"
IMAGE="ghcr.io/kyb/feishu-ws-cap:latest"

# Check if sidecar is running
if ! docker ps --filter "name=$SIDECAR_NAME" --format '{{.Status}}' | grep -q 'Up'; then
  echo "Sidecar $SIDECAR_NAME not running, re-creating..."

  # Remove stale container (if exists but stopped)
  docker rm -f "$SIDECAR_NAME" 2>/dev/null || true

  # Re-create
  docker run -d \
    --name "$SIDECAR_NAME" \
    --network "container:$TARGET_NAME" \
    --restart unless-stopped \
    "$IMAGE" \
    --upstream wss://msg-frontier.feishu.cn:443 \
    --listen :9443 \
    --health :9444
fi
```

Run this every 60s via cron or the infra-boss patrol loop.

### 8.3 Rollback

```bash
docker rm -f kyb-infra-feishu-ws-cap
docker run -d ... feishu-ws-cap:previous-tag ...
```

Zero risk to cc-connect — the sidecar is stateless. Rollback is a container recreate.

---

## 9. Monitoring

### 9.1 Grafana Panels

Reuse the panels from `proxy-intercept.md` Section 6.3, adding a `sidecar` filter:

| Panel | Query Addition | Purpose |
|-------|---------------|---------|
| WS throughput | `WHERE sidecar='feishu-ws-cap'` | Filter by capture source |
| Sidecar health | Prometheus: `docker_container_status{name="kyb-infra-feishu-ws-cap"}` | Container up/down |
| Frame log rate | `count() / 60 WHERE sidecar='feishu-ws-cap'` | Frames per minute from this sidecar |
| Capture gap | `max(ts) - min(ts) WHERE sidecar='feishu-ws-cap' GROUP BY conn_id` | Detect missed capture windows |

### 9.2 Alerting Rules

| Alert | Condition | Severity | Action |
|-------|-----------|----------|--------|
| SidecarDown | Container not running for > 30s | P2 | Recreate sidecar, alert if persistent |
| CaptureSilence | No frames in `cc.ws_frames` for > 5 min while cc-connect is running | P2 | Check Vector, check sidecar health |
| FrameGap | Sequence gap detected (`frame_seq` jumps by > 1) | P3 | Log; likely benign (reconnect reset) |

### 9.3 Patrol Integration

Add to the existing patrol check (`5min-patrol-guide.md`):

```bash
# check: feishu-ws-cap sidecar health
if ! docker ps --filter "name=kyb-infra-feishu-ws-cap" --format '{{.Status}}' | grep -q 'Up'; then
  echo "WARNING: feishu-ws-cap sidecar not running"
fi

# check: recent frames in CK
FRAMES_5M=$(curl -s "http://host.orb.internal:8123/?query=SELECT+count()+FROM+cc.ws_frames+WHERE+ts+>+now()-INTERVAL+5+MINUTE+AND+sidecar='feishu-ws-cap'&default_format=TabSeparated")
if [ "$FRAMES_5M" -eq 0 ]; then
  echo "WARNING: No WS frames captured in last 5 minutes"
fi
```

---

## 10. Comparison: Sidecar vs Process Injection

| Aspect | Sidecar (this design) | Process Injection (proxy-intercept.md) |
|--------|----------------------|----------------------------------------|
| **Containers** | 2 (cc-connect + sidecar) | 1 (cc-connect + proxy subprocess) |
| **Image size** | +5-10 MB (separate image) | +5-10 MB (included in cc-connect image) |
| **Lifecycle coupling** | Independent | Tied to cc-connect |
| **Update risk** | Zero (sidecar stops, cc-connect reconnects) | Requires cc-connect restart |
| **Resource isolation** | Separate cgroups (CPU/mem limits) | Shared with cc-connect |
| **Health signal** | Container healthcheck + /health endpoint | Process-level only |
| **Rollback** | `docker rm + docker run` previous tag | Rebuild cc-connect image |
| **Network config** | `--network container:cc-connect` | None (same container) |
| **Stdout separation** | Sidecar stdout → Vector → CK | Same stdout as cc-connect (must filter) |
| **Log driver isolation** | Independent log config per container | Shared log driver config |
| **Debugging** | `docker logs feishu-ws-cap` | `docker logs cc-connect \| grep proxy` |
| **Operational overhead** | Higher (manage 2 containers) | Lower (single container) |
| **Compose complexity** | 2 services, shared network namespace | 1 service, no extra config |

### 10.1 When to Choose Sidecar

- **Independent update cadence**: You want to update the capture proxy without restarting cc-connect
- **Resource isolation**: cc-connect is memory-sensitive and you don't want the proxy competing
- **Separate logging**: You want clean log separation between cc-connect and the proxy
- **Different reliability requirements**: Sidecar can have a different restart policy than cc-connect
- **Multi-cluster rollout**: Deploy sidecar independently across clusters, test on one cluster first

### 10.2 When to Choose Process Injection

- **Simplest deployment**: Single container, nothing to coordinate
- **No shared network namespace needed**: Same container = same localhost
- **Tightly coupled versions**: Certain cc-connect versions only work with specific proxy versions
- **Resource-constrained hosts** (e.g., Aliyun sim with 2 GB RAM): Avoid the overhead of an extra container

### 10.3 Recommendation

| Cluster | Approach | Rationale |
|---------|----------|-----------|
| **Mac/Orbstack** (32 GB RAM) | **Sidecar** | Resource-rich, independent lifecycle justifies the extra container |
| **Aliyun sim** (2 GB RAM) | **Process injection** | Resource-constrained, avoid container overhead |
| **Office nuc8** (8 GB RAM) | **Either** | Both viable; start with process injection for simplicity |

---

## 11. Implementation Plan

### Phase 1: Build Sidecar Binary (1 day)

- [ ] Go binary: WS relay (bidirectional forwarding)
- [ ] Go binary: JSON frame logger (stdout)
- [ ] Go binary: Health endpoint
- [ ] Dockerfile: multi-stage build (golang build → scratch runtime)
- [ ] Dockerfile: size target < 10 MB

### Phase 2: Integration (0.5 day)

- [ ] Docker Compose snippet for cc-connect + sidecar
- [ ] Vector config for parsing sidecar stdout → ClickHouse
- [ ] Verify: `docker logs feishu-ws-cap` shows JSON frames
- [ ] Verify: frames landing in `cc.ws_frames`

### Phase 3: Lifecycle Tooling (0.5 day)

- [ ] Sidecar watch script (`infra/observability/sidecar-watch.sh`)
- [ ] Update procedure documented
- [ ] Rollback procedure documented

### Phase 4: Monitoring (0.5 day)

- [ ] Grafana panels (with `sidecar` filter)
- [ ] Alert rules
- [ ] Patrol integration

---

## 12. Open Questions

| Question | Options | Decision Needed |
|----------|---------|-----------------|
| Sidecar image registry | (a) GitHub Container Registry (ghcr.io) (b) Docker Hub (c) Build locally from kyb repo | Depends on CI pipeline |
| Shared network namespace vs compose network | (a) `network_mode: "service:cc-connect"` (b) Same compose network, connect by container name | (a) is simpler for loopback; (b) needs DNS |
| cc-connect WS endpoint configuration | (a) Env var `FEISHU_WS_URL` (b) Config file `proxy_url` (c) Hardcoded | Verify cc-connect supports (a) or (b) |
| Vector placement | (a) Host-level daemon (b) Per-service sidecar (c) Aggregate in cc-connect container | Reuse existing Vector deployment decision from `sidecar-pattern.md` |
| Frame deduplication | (a) At proxy level (b) At CK query time (c) Not needed | Decide after observing real duplicate patterns |

---

## 13. Related Documents

- `proxy-intercept.md` — MITM proxy design (process injection approach, frame format, CK schema)
- `sidecar-pattern.md` — General sidecar pattern for observability per container
- `cc-ws-health.md` — WebSocket health monitoring (consumes frame data for health signals)
- `otel-cc-connect.md` — OTel tracing for cc-connect (complementary observability)
- `feishu-delivery.md` — Feishu bot delivery monitoring (consumes frame data for delivery confirmation)
- `cc-hooks-direct-ck.md` — Native hooks to ClickHouse (alternative observability path)
- `multi-cluster-boss-architecture.md` — Cluster topology and deployment context

---

## 14. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Deployment model | Sidecar container (separate from cc-connect) | Independent lifecycle, resource isolation, clean stdout separation |
| Frame format | JSON lines to stdout (compatible with proxy-intercept.md) | Reuses existing Vector → CK pipeline; identical schema |
| Network model | `--network container:cc-connect` (shared netns) | Simplest approach: loopback WS, no DNS, no port conflicts |
| Language | Go | Static binary, excellent WS libraries, small image size |
| Binary distribution | Docker image (multi-stage build) | Container-native; no host dependencies |
| Bypass mechanism | Health endpoint + manual operator action (Phase 1) | DNS-based bypass added in Phase 2 if needed |

---

> **Summary**: The sidecar intercept pattern decouples Feishu WS capture from cc-connect's lifecycle, providing independent updates, resource isolation, and clean log separation. At ~540 frames/day (108 KB/day), the operational cost is negligible. The sidecar is recommended for resource-rich clusters (Mac/Orbstack) while process injection remains suitable for resource-constrained hosts (Aliyun sim).

> ／人◕ ‿‿ ◕人＼
