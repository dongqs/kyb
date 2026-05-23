---
decision: 稍后做
---

# Docker Network Traffic Interception on kyb-net

**Design doc:** `docs/infra/reviews/docker-net-intercept.md`
**Date:** 2026-05-23
**Scope:** Docker-level packet capture and monitoring of Feishu traffic on `kyb-net` using tcpdump, PCAP analysis, and complementary pipeline to the MITM proxy approach.

---

## 1. Motivation

The existing [proxy-intercept design](./proxy-intercept.md) inserts a MITM proxy between `cc-connect` and Feishu to capture **application-layer** WebSocket frames. However, there are monitoring scenarios that the proxy layer cannot address:

| Gap | Impact |
|-----|--------|
| **No TCP-level visibility** | Connection resets, retransmissions, RTT variance, packet loss are invisible to the proxy |
| **No TLS handshake insight** | Cannot measure TLS negotiation time, cipher negotiation, certificate errors |
| **No pre-proxy traffic** | Before the proxy is deployed, no historical packet data exists |
| **No encrypted traffic metadata** | Packet sizes, timing patterns, and flow direction are available at the packet level |
| **No network-level diagnostics** | DNS resolution latency, TCP window scaling, MTU issues, kernel-level drops |
| **No zero-day capture** | When the proxy is not yet deployed for a new service, packet capture fills the gap |

A Docker-native interception layer on `kyb-net` complements the proxy by providing **network-layer observability** — no application modification, no proxy dependency, and no service downtime.

---

## 2. Current Architecture

All kyb infra containers are connected to `kyb-net`, a user-defined Docker bridge network:

```
┌─────────────────────────────────────────────┐
│  kyb-net (Docker bridge network)             │
│                                              │
│  ┌──────────────────────┐                    │
│  │ kyb-infra-cc-connect  │                    │
│  │ WSS → msg-frontier    │                    │
│  │ .feishu.cn:443        │                    │
│  ├───────────────────────┤                    │
│  │ kyb-infra-sing-box    │                    │
│  │ (SOCKS5 proxy :2080)  │                    │
│  ├───────────────────────┤                    │
│  │ kyb-infra-boss (×N)   │                    │
│  ├───────────────────────┤                    │
│  │ kyb-infra-clickhouse   │                    │
│  ├───────────────────────┤                    │
│  │ kyb-infra-grafana     │                    │
│  ├───────────────────────┤                    │
│  │ kyb-infra-postgresql-*│                    │
│  ├───────────────────────┤                    │
│  │ kyb-infra-kafka       │                    │
│  ├───────────────────────┤                    │
│  │ kyb-infra-redis       │                    │
│  └───────────────────────┘                    │
│                                              │
│  Docker DNS (127.0.0.11)                     │
│  Container name resolution                   │
└──────────────────────────────────────────────┘
         │
         │ eth0 (172.x.x.x /16)
         │
    [Docker host] ─── sing-box ─── WAN
```

`cc-connect` connects to `wss://msg-frontier.feishu.cn:443` via the sing-box proxy (SOCKS5 at `kyb-infra-sing-box:2080`). All traffic passes through `kyb-net` in both directions.

---

## 3. Design Goals

1. **Capture** — PCAP-level recording of all Feishu-bound traffic (or traffic to any target) on `kyb-net`
2. **Minimal overhead** — <1% CPU, <64 MB RAM, zero packet loss under normal load
3. **Non-invasive** — no changes to `cc-connect`, `sing-box`, or any other container; no network restart
4. **Self-contained** — capture container is ephemeral: start, capture, stop, analyze
5. **Structured output** — from raw PCAP to queryable ClickHouse tables
6. **Complementary** — works alongside the MITM proxy, not instead of it

---

## 4. Capture Approaches

### 4.1 Approach A: tcpdump sidecar with shared network namespace (Recommended for targeted capture)

Run a tcpdump container that shares `cc-connect`'s network namespace. This gives the capture process access to the same network interface as `cc-connect`.

```
┌────────────────────────────────────────────┐
│  kyb-net                                   │
│                                            │
│  ┌────────────────┐  ┌──────────────────┐  │
│  │ kyb-infra-cc-   │  │ kyb-net-cap      │  │
│  │ connect         │  │ (tcpdump sidecar) │  │
│  │                 │  │                   │  │
│  │ WSS → feishu    │  │ tcpdump -i eth0   │  │
│  │ .feishu.cn:443  │  │ host feishu-ip    │  │
│  └──────┬─────────┘  └────────┬──────────┘  │
│         │                     │              │
│         └───────┬─────────────┘              │
│                 │  shared network namespace   │
│                 │  (same eth0, same IP)       │
└──────────────────────────────────────────────┘
```

**How it works:**

```bash
# Create a privileged tcpdump sidecar sharing cc-connect's network namespace
docker run -d \
  --name kyb-net-cap \
  --network container:kyb-infra-cc-connect \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  -v /data/capture:/capture \
  alpine:latest \
  sh -c 'apk add tcpdump && tcpdump -i eth0 -s 0 \
    -w /capture/feishu-$(date +%Y%m%d-%H%M%S).pcap \
    "host msg-frontier.feishu.cn or port 443"'
```

**Advantages:**
- Captures traffic **to and from** cc-connect only (no cross-contamination from other containers)
- Same IP address as cc-connect — packet flow is identical to what cc-connect sees
- Zero modification to cc-connect's configuration or restart needed
- Sidecar can be started/stopped independently

**Disadvantages:**
- Requires `--cap-add NET_ADMIN` and `NET_RAW` (privileged)
- Need to resolve Feishu IPs in advance for BPF filter, OR use `port 443` heuristically
- Shared namespace means the sidecar's loopback traffic is also cc-connect's loopback

### 4.2 Approach B: tcpdump on the Docker bridge interface (Recommended for broad capture)

Attach to the Docker bridge (`br-<id>` for `kyb-net`) from the host or a privileged container. This captures **all** traffic on `kyb-net`, not just one container's.

```
┌────────────────────────────────────────────┐
│  kyb-net (br-xxxxxx)                       │
│                                            │
│  ┌────────────────┐                        │
│  │ kyb-infra-cc-   │                       │
│  │ connect         │                       │
│  └────────────────┘                        │
│  ┌────────────────┐                        │
│  │ kyb-infra-      │                       │
│  │ sing-box        │                       │
│  └────────────────┘                        │
│  ┌────────────────┐  ┌──────────────────┐  │
│  │ other kyb-net   │  │ kyb-bridge-cap   │  │
│  │ containers      │  │ (tcpdump)        │  │
│  └────────────────┘  │                  │  │
│                       │ tcpdump -i eth0  │  │
│                       │ on host network  │  │
│                       └──────────────────┘  │
└──────────────────────────────────────────────┘
```

**How it works:**

```bash
# Find the bridge interface for kyb-net
BRIDGE_IF=$(docker network inspect kyb-net -f '{{.Id}}' | cut -c1-12)
# Bridge interface name: br-${BRIDGE_IF:0:12}

# Run tcpdump in a container with host network access
docker run -d \
  --name kyb-bridge-cap \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  -v /data/capture:/capture \
  alpine:latest \
  sh -c "apk add tcpdump && tcpdump -i br-${BRIDGE_IF} -s 0 \
    -w /capture/kyb-net-$(date +%Y%m%d-%H%M%S).pcap \
    'port 443'"
```

**Advantages:**
- Single capture point for all containers on `kyb-net`
- Can see inter-container traffic (e.g., cc-connect ↔ clickhouse, cc-connect ↔ sing-box)
- Host network mode avoids Docker NAT visibility issues
- Capture filter can target any container by MAC/IP

**Disadvantages:**
- `--network host` is less isolated (can see all host traffic, not just kyb-net)
- Bridge interface name changes if `kyb-net` is recreated (must resolve dynamically)
- Captures all bridge traffic, not just Feishu — more noise to filter

### 4.3 Approach C: iptables TEE/NFLOG rule on kyb-net (Recommended for zero-copy packet mirroring)

Use Docker's built-in iptables integration to install a TEE/NFLOG rule that copies packets to a capture interface. No sidecar needed — the kernel does the mirroring.

```
┌─────────────────────────────────────────────┐
│  kyb-net bridge (br-xxxx)                    │
│                                              │
│  ┌────────────────────┐                      │
│  │ veth-cc-connect     │                     │
│  └────────┬───────────┘                      │
│           │                                   │
│           │  iptables TEE rule on FORWARD     │
│           │  chain: copy to capture target    │
│           │                                   │
│           ├──────────────────────────────┐    │
│           │                              │    │
│           ▼                              ▼    │
│  ┌──────────────┐              ┌───────────┐  │
│  │ To WAN       │              │ veth-cap   │  │
│  │ (sing-box)   │              │           │  │
│  └──────────────┘              │ tcpdump   │  │
│                               │ running   │  │
│                               │ in cap     │  │
│                               │ container  │  │
│                               └───────────┘  │
└──────────────────────────────────────────────┘
```

**How it works:**

```bash
# 1. Create a capture container with a dedicated veth pair on kyb-net
docker run -d \
  --name kyb-cap-agent \
  --network kyb-net \
  --cap-add NET_ADMIN \
  alpine:latest \
  sh -c 'apk add tcpdump iptables && tcpdump -i eth0 -w /dev/null'

# 2. Get the container's IP on kyb-net
CAP_IP=$(docker inspect kyb-cap-agent -f '{{.NetworkSettings.Networks.kyb-net.IPAddress}}')

# 3. On the host, install mirroring rules for cc-connect's traffic
CC_MAC=$(docker inspect kyb-infra-cc-connect -f '{{.NetworkSettings.Networks.kyb-net.MacAddress}}')

# Mirror inbound (from WAN to cc-connect)
iptables -t mangle -A PREROUTING -m mac --mac-source ${CC_MAC} -j TEE --gateway ${CAP_IP}

# Mirror outbound (from cc-connect to WAN)
iptables -t mangle -A POSTROUTING -m mac --mac-destination ${CC_MAC} -j TEE --gateway ${CAP_IP}
```

**Advantages:**
- Zero impact on cc-connect's packet path (true mirror, no interception)
- Kernel-level, no userspace overhead in the capture target path
- Can mirror specific flows (by MAC, IP, port) without touching the target container
- No `--network container:` dependency — capture container is independent

**Disadvantages:**
- Requires iptables `mangle` table access (NET_ADMIN on the host or a privileged container)
- iptables rules must be reinstalled after Docker daemon restart (Docker rewrites iptables)
- TEE gateway must be on the same L2 network (kyb-net) — works because Docker bridge is L2
- Mirroring adds 1:1 packet copy overhead in the kernel (negligible <1000 pps)
- No iptables persistence — need a bootstrap script or daemon to reinstall rules

### 4.4 Approach D: Docker network plugin / macvlan / ipvlan (Advanced)

Use macvlan or ipvlan driver to give the capture container direct access to the physical network, then use a hardware or software port mirror.

**Not recommended** for kyb's current scale. macvlan/ipvlan require the Docker host's physical NIC, are incompatible with overlay networks, and offer no advantage over the bridge-based approaches above for a single-host deployment.

---

## 5. Recommended Architecture (Hybrid)

For kyb's current scale (single host OrbStack, ~20 containers on `kyb-net`, <1000 Feishu messages/day), a **hybrid of Approaches A and C** is recommended:

### 5.1 Long-term: iptables TEE on kyb-net (persistent)

The iptables TEE approach provides the cleanest separation: the capture container is an independent entity on `kyb-net`, receiving mirrored packets. It captures continuously in a ring buffer.

```
┌────────────────────────────────────────────────────┐
│                   OrbStack Host                     │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  kyb-net bridge                              │   │
│  │                                              │   │
│  │  cc-connect ───── all traffic TEE'd ────────►│   │
│  │  sing-box                                      │   │
│  │  boss(es)             TEE mirror               │   │
│  │  clickhouse             │                      │   │
│  │  ...                ┌───┴────────────┐         │   │
│  │                     │ kyb-net-cap    │         │   │
│  │                     │                │         │   │
│  │                     │ tcpdump ring   │         │   │
│  │                     │ buffer (1GB)   │         │   │
│  │                     └───────┬────────┘         │   │
│  └─────────────────────────────┼───────────────────┘   │
│                                │                       │
│                                ▼                       │
│  ┌─────────────────────────────────────────┐           │
│  │  Analysis pipeline                       │           │
│  │                                         │           │
│  │  tcpdump ring  ──► PCAP rotate ──►      │           │
│  │  (1 GB, wrap)      every 1 GB or 24h    │           │
│  │                      │                  │           │
│  │                      ▼                  │           │
│  │  ┌─────────────────────────────┐        │           │
│  │  │ tsfeishu (packet analyzer)  │        │           │
│  │  │                             │        │           │
│  │  │ PCAP → TLS metadata         │        │           │
│  │  │       → DNS queries         │        │           │
│  │       → TCP metrics (RTT,     │        │           │
│  │         retransmit, window)   │        │           │
│  │       → Flow records          │        │           │
│  │  └──────────────┬──────────────┘        │           │
│  │                 │                       │           │
│  │                 ▼                       │           │
│  │  ┌─────────────────────────────┐        │           │
│  │  │ ClickHouse (net.feishu_*)   │        │           │
│  │  └─────────────────────────────┘        │           │
│  └─────────────────────────────────────────┘           │
└────────────────────────────────────────────────────────┘
```

### 5.2 Ad-hoc: tcpdump sidecar (for targeted debugging)

When debugging a specific issue (e.g., "cc-connect keeps disconnecting"), start the sidecar in Approach A for fine-grained capture of just that container:

```bash
# Quick capture for 60 seconds
docker run --rm \
  --network container:kyb-infra-cc-connect \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v $(pwd):/capture \
  alpine:latest \
  sh -c 'apk add tcpdump && \
    tcpdump -i eth0 -G 60 -W 1 \
    -w /capture/cc-connect-%Y%m%d-%H%M%S.pcap \
    "port 443"'
```

---

## 6. Capture Container Design

### 6.1 Image

```dockerfile
# Dockerfile.kyb-net-cap
FROM alpine:3.20

RUN apk add --no-cache tcpdump tshark jq curl

# Entrypoint: configurable capture
COPY cap-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["cap-entrypoint.sh"]
```

### 6.2 Entrypoint

```bash
#!/bin/sh
# cap-entrypoint.sh
# ky b-net capture container entrypoint

INTERFACE="${INTERFACE:-eth0}"
FILTER="${FILTER:-port 443}"
RING_SIZE="${RING_SIZE:-1000}"  # MB
ROTATE_INTERVAL="${ROTATE_INTERVAL:-3600}"  # seconds
CAPTURE_DIR="${CAPTURE_DIR:-/capture}"

mkdir -p "$CAPTURE_DIR"

if [ "$1" = "analyze" ]; then
  # Analysis mode: process existing PCAP files
  exec tshark -r "$2" -T fields \
    -e frame.time_epoch \
    -e ip.src -e ip.dst \
    -e tcp.srcport -e tcp.dstport \
    -e tcp.stream \
    -e tcp.analysis.ack_rtt \
    -e tcp.analysis.retransmission \
    -e tcp.analysis.fast_retransmission \
    -e tls.handshake.type \
    -e tls.handshake.ciphersuite \
    -e dns.qry.name \
    -Y "tls or dns or tcp.analysis.flags"
else
  # Capture mode: ring buffer with rotation
  exec tcpdump -i "$INTERFACE" -s 0 \
    -C "$RING_SIZE" -W 10 \
    -z "gzip" \
    -w "$CAPTURE_DIR/capture-%Y%m%d-%H%M%S.pcap" \
    "$FILTER"
fi
```

### 6.3 Deployment

```bash
# Start capture container (persistent, TEE mirror)
docker run -d \
  --name kyb-net-cap \
  --network kyb-net \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  -v /data/capture:/capture \
  kyb-net-cap:latest \
  -i eth0 \
  "host msg-frontier.feishu.cn"

# Verify capture is running
docker logs kyb-net-cap --tail 5
# Expected: "tcpdump: listening on eth0, link-type EN10MB (Ethernet), capture size 262144 bytes"

# Quick health check (packets per second)
docker exec kyb-net-cap sh -c \
  'tcpdump -i eth0 -c 100 -w /dev/null 2>&1 | tail -1'
```

---

## 7. TLS Considerations

Feishu traffic is WSS over TLS 1.3 — payloads are encrypted on the wire. Packet capture reveals metadata only:

### 7.1 Visible in PCAP (with tcpdump)

| Field | Example | Value |
|-------|---------|-------|
| Source IP | `172.x.x.x` | cc-connect container IP on kyb-net |
| Destination IP | `x.x.x.x` | Feishu server IP (msg-frontier.feishu.cn) |
| Source port | `43210` | Ephemeral |
| Destination port | `443` | HTTPS/WSS |
| Packet size | `54-1500 bytes` | Full packet (including TLS record headers) |
| TCP flags | `SYN, ACK, FIN, RST` | Connection lifecycle |
| TCP window | `65535` | Window scaling and advertised window |
| TCP RTT | `12.3 ms` | Round-trip time per segment |
| Retransmissions | `1` | Packet loss indicator |
| TLS record type | `23` (Application Data), `22` (Handshake) | Can distinguish handshake from data |
| TLS version | `0x0304` (TLS 1.3) | From ClientHello |
| SNI | `msg-frontier.feishu.cn` | From ClientHello (TLS handshake) |
| DNS queries | `msg-frontier.feishu.cn → x.x.x.x` | Resolution and timing |

### 7.2 Visible in PCAP (with tshark deep dissection)

With `tshark` (Wireshark CLI), additional TLS handshake metadata is extractable:

```bash
# TLS handshake metadata (non-encrypted portion)
tshark -r capture.pcap -Y tls.handshake \
  -T fields \
  -e tls.handshake.ciphersuite \
  -e tls.handshake.extensions_server_name \
  -e tls.handshake.type

# TCP connection metrics per stream
tshark -r capture.pcap -Y tcp.analysis.flags \
  -T fields \
  -e tcp.stream \
  -e tcp.analysis.ack_rtt \
  -e tcp.analysis.retransmission \
  -e tcp.analysis.bytes_in_flight
```

### 7.3 NOT Visible (TLS encrypted)

| Field | Why Not Visible |
|-------|----------------|
| WebSocket opcode | Inside TLS record payload |
| Message content | Encrypted with TLS 1.3 session key |
| Feishu message_id | Inside encrypted application data |
| Heartbeat frames | Indistinguishable from data frames (TLS 1.3) |

### 7.4 Mitigation: Combined with MITM Proxy

For application-layer visibility, the MITM proxy (see [proxy-intercept.md](./proxy-intercept.md)) terminates TLS and exposes frame contents. The two layers together provide:

```
Docker-level capture (tcpdump)    Application-level capture (proxy)
────────────────────────────     ────────────────────────────────
TCP connection metrics            WebSocket frame contents
TLS handshake timing              Message-level payloads
Packet loss / retransmit          Protocol-level errors
DNS resolution timing             Message ID tracking
Traffic volume (bytes/pkt)        Full payload truncation
Flow duration                     Replay capability
```

---

## 8. Analysis Pipeline

### 8.1 Overview

```
                              ┌──────────────┐
                              │  kyb-net-cap  │
                              │  (tcpdump)    │
                              └──────┬───────┘
                                     │
                           PCAP files (rotated)
                                     │
                                     ▼
┌──────────────────────────────────────────────────┐
│  tsfeishu (packet-to-event analyzer)              │
│                                                   │
│  tsfeishu --pcap capture.pcap --output json       │
│                                                   │
│  Outputs:                                         │
│  - net.feishu_flows     (TCP flow records)        │
│  - net.feishu_tls       (TLS handshake metadata)  │
│  - net.feishu_metrics   (time-series aggregates)  │
│  - net.feishu_dns       (DNS queries/timing)      │
│  - net.feishu_errors    (TCP errors, drops)       │
└──────────────────────┬───────────────────────────┘
                       │
                       ▼
              ┌────────────────┐
              │  Vector        │
              │  (or direct)   │
              └───────┬────────┘
                      │
                      ▼
              ┌────────────────┐
              │  ClickHouse    │
              └────────────────┘
```

### 8.2 ClickHouse Schema

**Flow table** — one row per TCP connection:

```sql
CREATE TABLE net.feishu_flows (
    ts_start            DateTime64(3),
    ts_end              DateTime64(3),
    duration_ms         UInt32,
    src_ip              IPv4,
    dst_ip              IPv4,
    dst_port            UInt16,
    tcp_stream          UInt64,
    packets_src         UInt32,
    packets_dst         UInt32,
    bytes_src           UInt64,
    bytes_dst           UInt64,
    avg_rtt_ms          Float32,
    max_rtt_ms          Float32,
    min_rtt_ms          Float32,
    retransmits         UInt16,
    fast_retransmits    UInt16,
    window_min          UInt32,
    window_max          UInt32,
    tls_version         String,          -- 'TLSv1.3', 'TLSv1.2', or ''
    tls_ciphersuite     String,          -- hex code or name
    tls_sni             String,          -- Server Name Indication
    close_reason        String,          -- 'FIN', 'RST', or 'timeout'
    cap_hostname        LowCardinality(String)  -- which capture node
) ENGINE = MergeTree
ORDER BY (toDate(ts_start), dst_ip, tcp_stream)
TTL toDate(ts_start) + INTERVAL 90 DAY;
```

**Metrics table** — time-series aggregates every 60 seconds:

```sql
CREATE TABLE net.feishu_metrics (
    ts                  DateTime,
    interval_sec        UInt8 DEFAULT 60,
    dst_ip              IPv4,
    packets_per_sec     Float64,
    bytes_per_sec       Float64,
    active_connections  UInt16,
    new_connections     UInt16,
    closed_connections  UInt16,
    retransmit_rate     Float32,        -- retransmits / total packets
    avg_rtt_ms          Float32,
    max_rtt_ms          Float32,
    tls_handshake_ms    Float32,        -- avg TLS handshake duration
    dns_resolution_ms   Float32
) ENGINE = MergeTree
ORDER BY (toDate(ts), dst_ip)
TTL toDate(ts) + INTERVAL 90 DAY;
```

**DNS table** — each DNS query/response:

```sql
CREATE TABLE net.feishu_dns (
    ts                  DateTime64(3),
    query               String,
    answer              String,         -- resolved IP(s)
    response_ms         Float32,        -- DNS resolution time
    rcode               UInt8,          -- 0 = NOERROR
    cap_hostname        LowCardinality(String)
) ENGINE = MergeTree
ORDER BY (toDate(ts), query)
TTL toDate(ts) + INTERVAL 30 DAY;
```

### 8.3 tsfeishu Analyzer

A lightweight Go (or Python with scapy) tool that reads PCAP and emits structured events:

```bash
# Usage
tsfeishu [flags] <pcap-file>

Flags:
  --pcap <path>        PCAP file to analyze
  --dir <path>         Analyze all PCAPs in directory
  --live               Real-time analysis (follow new PCAPs)
  --output json        JSON lines to stdout (default)
  --output ck          Direct-to-ClickHouse (requires CK env vars)
  --filter "tcp port 443"   BPF filter for analysis scope
  --feishu-only        Auto-detect Feishu IPs from SNI
  --verbose            Show per-packet metadata

Environment:
  CK_HOST=clickhouse://host:8123   (for --output ck)
  CK_DATABASE=net
  CK_USER=
  CK_PASSWORD=
```

**Auto-detection of Feishu traffic:**

```
tsfeishu --pcap capture.pcap --feishu-only --output json
```

The `--feishu-only` flag:
1. Scans all TLS ClientHello messages for SNI matching `*.feishu.cn`
2. Extracts resolved IPs from DNS responses for those domains
3. Only emits flow/metric records for connections to those IPs
4. Falls back to port 443 + SNI scan for non-DNS captures

This avoids capturing inter-container traffic (PG, Redis, Kafka on kyb-net).

### 8.4 Scheduled Analysis

```bash
# Cron: analyze PCAPs every 5 minutes, ship to ClickHouse
*/5 * * * * tsfeishu --dir /data/capture --feishu-only --output ck
```

The analyzer tracks which PCAPs it has already processed via a state file (`/data/capture/.tsfeishu-state`) to avoid double-processing.

---

## 9. Grafana Panels

| Panel | Source | Query | Purpose |
|-------|--------|-------|---------|
| **Active Feishu Connections** | `net.feishu_metrics` | `sum(active_connections)` | How many WS connections currently open |
| **Connection Churn** | `net.feishu_metrics` | `rate(new_connections)` + `rate(closed_connections)` | Reconnect frequency |
| **Feishu Packet Loss** | `net.feishu_metrics` | `retransmit_rate` | Network reliability to feishu |
| **RTT to Feishu** | `net.feishu_metrics` | `avg_rtt_ms`, `max_rtt_ms` | Latency heatmap |
| **Feishu Throughput** | `net.feishu_metrics` | `bytes_per_sec` | Bandwidth usage |
| **TLS Handshake Time** | `net.feishu_metrics` | `tls_handshake_ms` | TLS negotiation performance |
| **DNS Resolution** | `net.feishu_dns` | `response_ms` by `query` | DNS performance |
| **TCP Flow Details** | `net.feishu_flows` | Table | Drill-down for specific time windows |
| **Error Table** | `net.feishu_flows` | `WHERE retransmits > 0 OR close_reason = 'RST'` | Connections with issues |

---

## 10. Operational Procedures

### 10.1 Start Continuous Capture

```bash
# Deploy persistent capture container
docker run -d \
  --name kyb-net-cap \
  --network kyb-net \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --restart unless-stopped \
  -v /data/capture:/capture \
  kyb-net-cap:latest \
  -i eth0 \
  "host msg-frontier.feishu.cn"

# Verify
docker ps --filter name=kyb-net-cap
```

### 10.2 Ad-hoc Targeted Capture

```bash
# Capture 30 seconds of traffic from cc-connect only
docker run --rm \
  --network container:kyb-infra-cc-connect \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  alpine:latest \
  sh -c "
    apk add tcpdump >/dev/null 2>&1
    tcpdump -i eth0 -G 30 -W 1 -w /tmp/cc-diag.pcap 'port 443'
    tshark -r /tmp/cc-diag.pcap -T fields \
      -e tcp.stream -e tcp.analysis.ack_rtt \
      -e tcp.analysis.retransmission \
      -e tls.handshake.extensions_server_name \
      -Y 'tcp.analysis.flags or tls.handshake'
  "
```

### 10.3 Analyze Existing PCAP

```bash
# Quick summary
tshark -r capture.pcap -q -z conv,tcp

# Extract Feishu-specific flows
tsfeishu --pcap capture.pcap --feishu-only --output json | jq '.'
```

### 10.4 Stop Capture

```bash
docker stop kyb-net-cap && docker rm kyb-net-cap

# Clean up (optional)
rm -rf /data/capture/*.pcap /data/capture/*.pcap.gz
```

### 10.5 Rotate and Archive

```bash
# Manual rotation
docker exec kyb-net-cap kill -INT 1  # SIGINT triggers tcpdump file close
# New file will be created automatically (tcpdump -C -W)

# Archive old captures
find /data/capture -name '*.pcap' -mtime +7 -exec gzip {} \;
find /data/capture -name '*.pcap.gz' -mtime +30 -delete
```

---

## 11. Overhead and Cost Estimates

### 11.1 Resource Usage

| Resource | Per-container sidecar (Approach A) | Bridge capture (Approach B) | TEE capture (Approach C) |
|----------|------------------------------------|----------------------------|--------------------------|
| CPU | <0.5% core | <1% core | <0.2% core (kernel copy) |
| Memory | ~32 MB (tcpdump buffer) | ~64 MB | ~16 MB (kernel buffer) |
| Disk (daily) | ~50 MB (Feishu only) | ~500 MB (all bridge traffic) | ~50 MB (filtered to feishu) |
| Network overhead | None | None | Mirror copy (negligible) |
| Privilege | NET_ADMIN + NET_RAW | NET_ADMIN + NET_RAW + host | NET_ADMIN (for iptables) |

### 11.2 Daily Capture Volume (Feishu only)

| Item | Per Message | Daily (90 messages) | Format |
|------|-------------|--------------------|--------|
| TCP overhead + TLS | ~2 KB | ~180 KB | Per connection |
| Application data (encrypted) | ~5 KB (avg) | ~450 KB | Per message |
| TLS handshake (initial) | ~6 KB | ~6 KB | Once per session |
| DNS queries | ~200 bytes | ~1 KB | ~5 queries/day |
| **Total PCAP** | **~7.2 KB** | **~637 KB** | Uncompressed |

Even with 10x safety margin: **~6.5 MB/day** for full Feishu PCAP capture.

At 30-day retention: **~195 MB** — negligible on a 260 GB SSD.

### 11.3 ClickHouse Storage

| Table | Daily Rows | Daily Size | 90-Day Size |
|-------|-----------|-----------|-------------|
| `net.feishu_flows` | ~900 | ~180 KB | ~16 MB |
| `net.feishu_metrics` | ~2,160 | ~540 KB | ~48 MB |
| `net.feishu_dns` | ~5 | ~2 KB | ~180 KB |
| **Total** | **~3,065** | **~722 KB** | **~64 MB** |

Well within existing infra-log capacity (~161 MB/day total from sidecar-pattern design).

---

## 12. Comparison with MITM Proxy

| Dimension | Docker Network Capture (this doc) | MITM Proxy (proxy-intercept.md) |
|-----------|-----------------------------------|---------------------------------|
| **Layer** | Network (L3-L4, partial L7 metadata) | Application (L7, full WebSocket frames) |
| **TLS payload visible?** | No (encrypted) | Yes (terminated) |
| **Container changes?** | None | Requires proxy sidecar + config change |
| **Dependency** | Docker only | Proxy binary (feishu-proxy) |
| **Overhead** | <0.5% CPU, no latency added | <1ms latency added per frame |
| **Fail-open** | Inherent (capture is read-only) | Requires DNS/health fallback design |
| **Replay capability** | No (cannot replay TLS payload) | Yes (full frame replay) |
| **TCP diagnostics** | Excellent (RTT, retransmit, window) | None (TLS tunnel hides TCP) |
| **Protocol errors** | TLS-level (handshake, cert) | WebSocket-level (opcodes, close codes) |
| **Deployment complexity** | Low (one docker run) | Medium (proxy binary + config + health) |
| **Historical debugging** | PCAP files replayable offline | No historical data without proxy |
| **Cross-service visibility** | Yes (can see inter-container traffic on kyb-net) | No (per-service proxy only) |

### Status

Both approaches are **complementary**, not competitive. Deploy both for full observability:

```
Docker net capture  ─── TCP health, TLS timing, DNS, volume
       +
MITM proxy          ─── Frame contents, message IDs, replay
       │
       ▼
Full Feishu observability
```

---

## 13. Implementation Plan

### Phase 1: Quick Wins (Day 1)

- [ ] Build `kyb-net-cap` Alpine-based image with tcpdump + tshark
- [ ] Write `cap-entrypoint.sh` for capture and analysis modes
- [ ] Deploy sidecar on `kyb-infra-cc-connect` (Approach A) for targeted Feishu capture
- [ ] Verify: `tcpdump` records packets, `tshark` extracts TLS metadata
- [ ] Verify: zero impact on cc-connect's throughput/latency

### Phase 2: Pipeline (Day 2)

- [ ] Write `tsfeishu` analyzer script (Python or Go) for PCAP → JSON → CK
- [ ] Create ClickHouse tables: `net.feishu_flows`, `net.feishu_metrics`, `net.feishu_dns`
- [ ] Vector config for tsfeishu JSON output (or direct CK HTTP insert)
- [ ] Grafana panels for network-level Feishu metrics
- [ ] Verify: end-to-end from packet to Grafana dashboard

### Phase 3: Production Hardening (Day 3)

- [ ] Switch to iptables TEE on kyb-net (Approach C) for zero-impact persistent capture
- [ ] `--restart unless-stopped` + iptables rule bootstrap script
- [ ] PCAP rotation and archiving (7-day hot, 30-day cold)
- [ ] Alert rules: retransmit rate > 5%, RTT > 500ms, DNS failures
- [ ] Document operational procedures and runbook

### Phase 4: Integration (Week 2)

- [ ] Cross-reference Feishu network metrics with application-level logs (by time window)
- [ ] Link `net.feishu_metrics` panels alongside proxy-level `cc.ws_frames` in Grafana
- [ ] Add network capture to the kyb-infra-boss heartbeat/patrol health checks
- [ ] Document the combined observability stack

---

## 14. Open Questions

| Question | Options | Decision Needed |
|----------|---------|-----------------|
| **Persistent vs ad-hoc** | (a) always-on capture on kyb-net (b) on-demand for debugging | Start with (b), move to (a) when pipeline is mature |
| **tsfeishu language** | (a) Go (static binary, same ecosystem as other infra tools) (b) Python + scapy (faster to prototype) (c) Rust (performance) | Go for consistency with cc-connect/feishu-proxy ecosystem |
| **PCAP rotation** | (a) Inside container with tcpdump -C -W (b) Host cron + logrotate | tcpdump built-in for simplicity |
| **iptables TEE on OrbStack?** | OrbStack may not support `mangle/TEE` in all configurations | Verify by testing `iptables -t mangle -A ... -j TEE` on OrbStack before committing to Approach C |
| **Feishu IP changes** | (a) Resolve dynamically from DNS (b) Hardcode known ranges (c) SNI-based auto-detection | SNI-based (tsfeishu --feishu-only) is most robust |
| **PII in PCAP?** | TLS encryption protects payload, but IP addresses and connection patterns may be sensitive | PCAPs stored on encrypted volume, access restricted to root |
| **Need full Feishu URL list?** | `msg-frontier.feishu.cn` is the primary WS endpoint, but there may be others (`open.feishu.cn` for REST API) | Expand capture filters as new Feishu endpoints are discovered |

---

## 15. Related Documents

- Proxy intercept design: `docs/infra/reviews/proxy-intercept.md`
- Sidecar pattern design: `docs/infra/reviews/sidecar-pattern.md`
- OTel observability for cc-connect: `docs/infra/reviews/otel-cc-connect.md`
- Multi-cluster architecture: `docs/infra/multi-cluster-boss-architecture.md`
- Heartbeat reliability scoring: `docs/infra/reviews/heartbeat-reliability.md`
- Bridge observability design: `docs/infra/observability-design.md`

---

> **Summary:** Docker network traffic interception on `kyb-net` provides network-layer observability for Feishu traffic — TCP metrics, TLS handshake timing, DNS resolution performance, and packet-level diagnostics — with zero changes to any container. ~637 KB/day PCAP storage, ~722 KB/day ClickHouse storage. Complements the MITM proxy by covering what TLS encryption hides: the health of the underlying network path.

> Three approaches evaluated: (A) tcpdump sidecar sharing cc-connect's network namespace, (B) tcpdump on the Docker bridge interface, (C) iptables TEE mirroring to a capture container. **Recommended: hybrid of A for ad-hoc debugging and C for persistent capture**, with iptables TEE providing the cleanest separation in production.

> ／人◕ ‿‿ ◕人＼
