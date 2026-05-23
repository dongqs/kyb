---
decision: 不应该做
---

# eBPF + tcpdump: TLS Key Extraction and Packet-Level Feishu Interception

**Date**: 2026-05-23
**Scope**: eBPF-based TLS session key extraction from feishu WSS/TLS connections, paired with tcpdump for full PCAP capture and offline decryption — a **fallback** to the MITM proxy approach (`proxy-intercept.md`).

---

## 1. Motivation

The MITM proxy approach (`docs/infra/reviews/proxy-intercept.md`) is the primary strategy for feishu traffic interception. It provides structured frame-level capture, replay, and ClickHouse storage with <1ms overhead. However, it has fundamental limitations:

| Scenario | Proxy Limitation | Fallback Required |
|----------|-----------------|-------------------|
| **Third-party containers** | Cannot inject a proxy between proprietary binaries and their upstream | Packet-level capture without binary modification |
| **Kernel-level networking** | Proxy sits at application layer; misses TCP-level events (retransmits, RSTs, window scaling) | tcpdump on the wire |
| **Incident forensics** | Proxy not yet deployed when incident occurs | Retroactive capture from existing traffic |
| **Binary verification** | Proxy modifies network path; need to verify the binary's behavior is unchanged | Zero-intrusion observation |
| **Scale debugging** | Proxy becomes a bottleneck at high frame rates (10k+ msg/min) | Kernel-level capture with zero-copy |
| **SSL/TLS library mismatch** | Proxy requires Go TLS; target uses BoringSSL/OpenSSL with custom verify | Hook at the TLS library boundary |

**When to use this approach**:
- You need to intercept traffic for a binary you cannot recompile or re-configure
- You're doing incident forensics on a live system where you cannot restart processes
- You need TCP-level metrics (retransmits, congestion windows, RTT) alongside application data
- The proxy approach failed or introduced latency in a specific deployment
- You need to verify the proxy itself is working correctly (cross-validation)

---

## 2. Current Architecture

```
Feishu (open.feishu.cn / msg-frontier.feishu.cn:443)
    │
    │ TLS 1.3 (WSS over HTTPS)
    │ ECDHE key exchange, AEAD encryption (AES-256-GCM / ChaCha20-Poly1305)
    ▼
Target Process (cc-connect / lark-cli / any Go binary)
    │
    │ TLS session keys exist in process memory
    │ Inside OpenSSL / BoringSSL / libtls structures
    ▼
No visibility:
    ├── Cannot inspect decrypted frames
    ├── Cannot measure frame-level timing
    ├── Cannot detect protocol errors (bad frames, reconnects)
    └── Cannot replay captured sessions
              ▲
              │ All traffic is opaque encrypted blobs
```

The key insight: **TLS session keys exist in the target process's memory**. If we can extract them at the right moment, we can decrypt any packet capture. eBPF is the tool for this — it can hook into the process at the kernel level without modifying the binary.

---

## 3. Design

### 3.1 Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│ Target Host                                                         │
│                                                                     │
│  ┌───────────────────┐              ┌──────────────────────────┐    │
│  │ Target Process     │              │ tcpdump                  │    │
│  │ (cc-connect)       │              │  (background capture)    │    │
│  │                    │              │                          │    │
│  │ OpenSSL/BoringSSL  │              │ pcap file(s):            │    │
│  │  ↕ eBPF hook       │              │  /data/capture/raw/      │    │
│  └────────┬───────────┘              │   feishu-2026-05-23.pcap │    │
│           │                          └──────────────────────────┘    │
│           │ session keys (SSLKEYLOGFILE format)                     │
│           ▼                                                         │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ eBPF Key Extractor                                           │   │
│  │  ┌──────────┐  ┌───────────┐  ┌───────────────────────────┐ │   │
│  │  │ BPF_PROG  │  │ Userspace │  │ Key File Writer           │ │   │
│  │  │ TYPE_KPROBE│  │ Tail/C    │  │ /data/capture/keys/       │ │   │
│  │  │ (hooks on │  │ eBPF map  │  │ feishu-SSLKEYLOG.log      │ │   │
│  │  │ key gen)  │  │ reader    │  │                           │ │   │
│  │  └──────────┘  └───────────┘  └───────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│                              │ Export for offline analysis          │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ Analysis Workstation                                         │   │
│  │  tshark -o tls.keylog_file:feishu-SSLKEYLOG.log              │   │
│  │   -r feishu-2026-05-23.pcap                                  │   │
│  │   -Y "tls.handshake.type == 1"                               │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

**Three-layer design**:

1. **eBPF probe layer** — kernel-level hooks into TLS key generation functions
2. **Userspace collector** — reads eBPF maps, writes SSLKEYLOGFILE-format file
3. **Offline analyzer** — Wireshark/tshark with key file decrypts the PCAP

### 3.2 eBPF Probe Layer

#### Target Functions to Hook

Two approaches depending on the target's TLS library:

**Approach A: OpenSSL / BoringSSL `SSL_*` functions** (most Go binaries, Python, Ruby)

| Function | Hook Type | Key Material Extracted | When Called |
|----------|-----------|----------------------|-------------|
| `SSL_connect` | kprobe | Server random (for session match) | Client hello sent |
| `SSL_do_handshake` | kretprobe | Handshake completion status | After each handshake step |
| `SSL_set_keylog_callback` | kprobe | (optional) Verify callback is registered | During SSL_CTX setup |
| `SSL_write` | kprobe | Connection fd + TLS record info | Per write |
| `SSL_read` | kprobe | Connection fd + TLS record info | Per read |
| `SSL_get_session` | kprobe | Session pointer | During key extraction |
| `SSL_SESSION_get_master_key` | kprobe | **Master secret** (48 bytes) | Key derivation |
| `SSL_get_client_random` | kprobe | **Client random** (32 bytes) | Handshake logging |
| `SSL_get_server_random` | kprobe | **Server random** (32 bytes) | Handshake logging |

The critical extraction point is `SSL_do_handshake` return (or `SSL_connect` return in blocking mode). At that point, the master secret is available in the SSL session structure.

**Approach B: Kernel TLS (kTLS)** — hook at the kernel crypto layer

For binaries using kTLS (kernel-assisted TLS offload), the key material lives in kernel structures:

| Hook | Key Material | Trigger |
|------|-------------|---------|
| `tls_set_sw_offload` kprobe | Session keys (crypto_info) | Each new TLS connection |
| `tls_device_offload` kprobe | Device-specific keys (NIC offload) | Hardware offload setup |
| `tls_encrypt_do` / `tls_decrypt_do` kprobe | Plaintext + IV | Per-record (if we need real-time plaintext) |

Approach B is more complex but covers cases where kTLS is active (common with nginx, haproxy, and modern kernels).

**Recommended**: Implement Approach A first (covers 90%+ of targets), with Approach B as a fallback for kTLS-heavy deployments.

#### eBPF Program Structure

```c
// tls_key_extractor.c — simplified sketch

// Per-instance key event, sent to userspace via perf ring buffer
struct key_event {
    u32 pid;
    u8  client_random[32];
    u8  server_random[32];  // TLS 1.2 only; TLS 1.3 uses different derivation
    u8  master_key[48];     // For TLS 1.2: master secret
    // For TLS 1.3: we need CLIENT_TRAFFIC_SECRET_0, SERVER_TRAFFIC_SECRET_0, etc.
    u8  traffic_secrets[4][32]; // TLS 1.3: up to 4 traffic secrets
    u8  tls_version;        // 0x0301=TLS1.0, 0x0303=TLS1.2, 0x0304=TLS1.3
    u64 conn_id;            // Connection identifier (socket fd or SSL* pointer)
};

// Map: SSL pointer -> connection metadata for correlation
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, u64);   // SSL* pointer
    __type(value, struct conn_meta);
} ssl_conn_map SEC(".maps");

// Hook SSL_do_handshake kretprobe
SEC("kretprobe/SSL_do_handshake")
int kprobe_SSL_do_handshake(struct pt_regs *ctx)
{
    u64 ssl_ptr = PT_REGS_PARM1(ctx);
    int ret = PT_REGS_RC(ctx);
    if (ret != 1) return 0;  // Not a successful handshake

    struct conn_meta *meta = bpf_map_lookup_elem(&ssl_conn_map, &ssl_ptr);
    if (!meta) return 0;

    struct key_event evt = {};
    evt.pid = bpf_get_current_pid_tgid() >> 32;
    evt.conn_id = ssl_ptr;

    // Read client_random from SSL structure
    // SSL->s3->client_random (32 bytes)
    u64 s3_offset;
    bpf_probe_read(&s3_offset, sizeof(s3_offset), (void*)(ssl_ptr + SSL_S3_OFFSET));
    bpf_probe_read(evt.client_random, 32, (void*)(s3_offset + CLIENT_RANDOM_OFFSET));

    // For TLS 1.2: read master_key via SSL_SESSION_get_master_key
    // The exact offset depends on SSL_SESSION structure layout
    // We use SSL_get_session(ssl) -> session->master_key
    u64 session_ptr;
    bpf_probe_read(&session_ptr, sizeof(session_ptr), (void*)(ssl_ptr + SSL_SESSION_OFFSET));
    bpf_probe_read(evt.master_key, 48, (void*)(session_ptr + MASTER_KEY_OFFSET));

    // Emit to userspace
    bpf_perf_event_output(ctx, &key_events, BPF_F_CURRENT_CPU, &evt, sizeof(evt));
    return 0;
}
```

**Version-specific offsets problem**: The major challenge with approach A is that structure offsets vary across:
- OpenSSL vs BoringSSL vs LibreSSL vs AWS-LC
- OpenSSL 1.0.x vs 1.1.x vs 3.0.x
- BoringSSL rolling releases (no version numbers)
- Go's crypto/tls with built-in TLS (no OpenSSL)

We solve this with a **probing phase** at startup (section 3.4).

#### Key File Format (SSLKEYLOGFILE)

The extracted keys must be written in NSS SSLKEYLOGFILE format for Wireshark/tshark compatibility:

```
# SSLKEYLOGFILE — extracted from PID 12345 (cc-connect)
# Timestamp: 2026-05-23T16:38:00Z
# Target: msg-frontier.feishu.cn:443
# TLS version: 1.3

# TLS 1.2 master key format:
CLIENT_RANDOM <hex_client_random_32bytes> <hex_master_secret_48bytes>

# TLS 1.3 traffic secret format:
SERVER_TRAFFIC_SECRET_0 <hex_client_random_32bytes> <hex_secret_32bytes>
EXPORTER_SECRET <hex_client_random_32bytes> <hex_secret_32bytes>
CLIENT_TRAFFIC_SECRET_0 <hex_client_random_32bytes> <hex_secret_32bytes>
CLIENT_TRAFFIC_SECRET_1 <hex_client_random_32bytes> <hex_secret_32bytes>
SERVER_TRAFFIC_SECRET_1 <hex_client_random_32bytes> <hex_secret_32bytes>
```

Wireshark 3.0+ and tshark support `(Pre-)Master-Secret log filename` with this format natively.

### 3.3 Userspace Collector

The userspace component (C or Go binary) attaches the eBPF program and reads events from the perf ring buffer:

```
┌──────────────────────────────────────────────┐
│ ebpf-key-extract (userspace daemon)           │
│                                                │
│  1. Load eBPF program (via libbpf / cilium/ebpf)│
│  2. Attach kprobes to target PID (or globally) │
│  3. Probing phase: auto-detect structure offsets│
│  4. Perf ring buffer reader loop              │
│  5. Write to SSLKEYLOGFILE-format file        │
│  6. Rotate on SIGHUP / size (100MB max)       │
│  7. Expose health endpoint (HTTP :9800/health) │
└──────────────────────────────────────────────┘
```

**CLI interface**:

```bash
# Attach to a running process by PID
ebpf-key-extract --pid 1234 --output /data/capture/keys/feishu-SSLKEYLOG.log

# Attach to a process by name (glob)
ebpf-key-extract --name cc-connect --output /data/capture/keys/feishu-SSLKEYLOG.log

# Attach globally (all processes, for forensic mode)
ebpf-key-extract --global --output /data/capture/keys/all-SSLKEYLOG.log

# Dry-run: detect TLS library and offsets without capturing keys
ebpf-key-extract --pid 1234 --detect-only
```

**Output format**:

```
Key file:     /data/capture/keys/feishu-SSLKEYLOG-2026-05-23.log
Metadata:     /data/capture/keys/feishu-SSLKEYLOG-2026-05-23.meta.json
PCAP (raw):   /data/capture/raw/feishu-2026-05-23.pcap (written by separate tcpdump)
```

Metadata JSON:
```json
{
  "capture_start": "2026-05-23T16:38:00.123Z",
  "capture_end": "2026-05-23T17:38:00.123Z",
  "target_pid": 1234,
  "target_process": "cc-connect",
  "tls_library": "BoringSSL",
  "tls_library_version": "rolling-20250501",
  "connections_tracked": 3,
  "keys_extracted": 3,
  "keys_tls12": 0,
  "keys_tls13": 3,
  "offsets_auto_detected": true,
  "ebpf_program_version": "1.0.0"
}
```

### 3.4 Probing Phase: Auto-Detect Structure Offsets

This is the most technically challenging part — eBPF programs need to know the exact memory layout of TLS structures, which vary across library versions. We solve this with a two-phase approach:

**Phase 1: Library Detection**

```bash
# Read /proc/<pid>/maps to find loaded TLS libraries
cat /proc/1234/maps | grep -E "(libssl|libcrypto|libboringssl|libtls)"

# Parse ELF headers to determine library type and version
readelf -n /usr/lib/x86_64-linux-gnu/libssl.so
readelf -p .comment /usr/lib/x86_64-linux-gnu/libcrypto.so

# For Go binaries with in-tree TLS (no shared library):
# The crypto/tls functions are statically linked; offsets are per-Go-version
```

**Phase 2: Offset Probing**

We ship a database of known structure layouts:

```json
{
  "known_offsets": {
    "OpenSSL-1.1.1": {
      "SSL_S3_OFFSET": 0x2f8,
      "CLIENT_RANDOM_OFFSET": 0x38,
      "SSL_SESSION_OFFSET": 0x500,
      "MASTER_KEY_OFFSET": 0x18,
      "MASTER_KEY_LENGTH": 48
    },
    "OpenSSL-3.0.0": {
      "SSL_S3_OFFSET": 0x310,
      "CLIENT_RANDOM_OFFSET": 0x40,
      "SSL_SESSION_OFFSET": 0x520,
      "MASTER_KEY_OFFSET": 0x20,
      "MASTER_KEY_LENGTH": 48
    },
    "BoringSSL-20250501": {
      "SSL_S3_OFFSET": 0x2e0,
      "CLIENT_RANDOM_OFFSET": 0x30,
      "SSL_SESSION_OFFSET": 0x4f0,
      "MASTER_KEY_OFFSET": 0x10,
      "MASTER_KEY_LENGTH": 48
    },
    "BoringSSL-20250401": {
      "SSL_S3_OFFSET": 0x2d8,
      "CLIENT_RANDOM_OFFSET": 0x28,
      "SSL_SESSION_OFFSET": 0x4e8,
      "MASTER_KEY_OFFSET": 0x08,
      "MASTER_KEY_LENGTH": 48
    }
  },
  "fallback": {
    "method": "heuristic_scan",
    "description": "Scan process heap for SSL_SESSION magic bytes to identify structure boundaries"
  }
}
```

**Fallback: Heuristic scan** — if no exact match is found:

```
1. Read known functions from the process memory:
   - SSL_get_client_random, SSL_do_handshake, SSL_get_session

2. Binary-analyze the functions to extract offset constants:
   - Look for memory load instructions (mov + offset) that access known structure fields
   - Cross-reference with known patterns

3. If heuristic fails: fall back to kTLS hooks (Approach B)
   - kTLS uses stable kernel struct offsets (kernel version maps)
   - No library-dependent offsets
```

**When all else fails**: switch to **tcpdump-only mode** with no decryption — you get packet-level metadata (connection timing, throughput, TCP state) but no application data.

### 3.5 tcpdump Integration

Parallel to the eBPF key extraction, tcpdump captures the raw wire traffic:

**Start command**:

```bash
# Capture all traffic to/from feishu, with CPU-affinity per core for performance
tcpdump -i any \
  -s 0 \
  -w /data/capture/raw/feishu-$(date +%Y-%m-%d-%H%M).pcap \
  -C 500 \
  -W 48 \
  -z gzip \
  "host msg-frontier.feishu.cn or port 443"
```

| Flag | Value | Rationale |
|------|-------|-----------|
| `-s 0` | Full packet capture | Need full TLS records for decryption |
| `-C 500` | 500 MB per file | Manageable file size for analysis |
| `-W 48` | 48 files = 24 GB max | 24-hour rolling window |
| `-z gzip` | Compress on rotation | ~10x compression ratio for TLS-encrypted PCAP |
| `host msg-frontier.feishu.cn` | Feishu IPs | Direct capture, no loopback noise |
| `or port 443` | Alternative if DNS changes | Port-based capture as safety net |

**How to get feishu IPs dynamically**:

```bash
# From the target host, before starting capture:
dig +short msg-frontier.feishu.cn
nslookup msg-frontier.feishu.cn
# Or watch /proc/<pid>/net/tcp for active connections:
grep ":01BB" /proc/1234/net/tcp  # 443 = 0x01BB hex

# Generate tcpdump filter:
FEISHU_IPS=$(dig +short msg-frontier.feishu.cn | tr '\n' ' ')
tcpdump -i any -w feishu.pcap "host $FEISHU_IPS"
```

### 3.6 Offline Decryption Analysis

Once you have the PCAP and the key file, decrypt and analyze:

**One-step decryption**:

```bash
tshark -r feishu-2026-05-23.pcap \
  -o tls.keylog_file:feishu-SSLKEYLOG.log \
  -Y "tls" \
  -T fields \
  -e frame.number \
  -e frame.time_epoch \
  -e tls.handshake.type \
  -e tls.record.content_type \
  -e tls.record.length \
  -e ip.src \
  -e ip.dst \
  -e tcp.srcport \
  -e tcp.dstport
```

**Extract application data** (decrypted WSS frames):

```bash
tshark -r feishu-2026-05-23.pcap \
  -o tls.keylog_file:feishu-SSLKEYLOG.log \
  -Y "tls.application_data" \
  -T fields \
  -e frame.time_epoch \
  -e tls.app_data \
  -e tcp.stream \
  > feishu-decrypted-frames.txt
```

**Convert to JSON for analysis**:

```bash
tshark -r feishu-2026-05-23.pcap \
  -o tls.keylog_file:feishu-SSLKEYLOG.log \
  -Y "tls.app_data" \
  -T jsonraw \
  > feishu-decrypted-frames.json
```

### 3.7 Correlation: Keys + PCAP + Process

For the captured data to be useful, we need to correlate key extraction events with pcap frames:

```
Time synchronization:
  tcpdump timestamp (CLOCK_REALTIME)  ──┬──  align to within 1ms
  eBPF key event timestamp (ktime)      ──┘

Connection matching:
  Client hello random (32 bytes) is the correlation key:
    - Extracted by eBPF at handshake time
    - Visible in pcap (TLS ClientHello.random)
    - Used as the key in SSLKEYLOGFILE format
    - Wireshark matches client_random ↔ key automatically

Result:
  For each TLS connection:
    1. PCAP records show TCP-level metrics (RTT, retransmits, window size)
    2. eBPF records show TLS handshake details (cipher suite, key exchange)
    3. Decrypted data shows WS frame content
    4. Process logs (stderr/stdout) show application-level events
```

---

## 4. Deployment

### 4.1 Runtime Requirements

| Component | Requirement | Notes |
|-----------|-------------|-------|
| **Kernel** | Linux 5.4+ (BPF_PROG_TYPE_KPROBE) | 5.10+ for BTf; 5.15+ for BPF CO-RE (recommended) |
| **Capabilities** | `CAP_BPF`, `CAP_SYS_ADMIN` (or `BPF_PERF_EVENT` + `BPF_LOAD` + `BPF_WRITE`) | Unprivileged BPF if kernel.unprivileged_bpf_disabled=0 |
| **Disk** | 500 MB / file (pcap), ~10 KB / key file | Rolling: 24 GB max for pcap, 10 MB for keys |
| **Memory** | ~50 MB for eBPF maps + userspace collector | Negligible for the target host |
| **Dependencies** | libbpf (or cilium/ebpf), tcpdump, tshark | All installable via apt |

### 4.2 Container Mode

If the target runs in Docker, the eBPF tools need access to the host kernel:

```yaml
version: "3.9"
services:
  cc-connect:
    image: cc-connect:latest
    # ... standard config ...

  ebpf-capture:
    image: capture-agent:latest
    pid: "service:cc-connect"              # Share PID namespace
    network: "service:cc-connect"           # Share network namespace
    cap_add:
      - BPF
      - SYS_ADMIN
      - NET_ADMIN
      - NET_RAW
    volumes:
      - /sys/kernel/btf:/sys/kernel/btf:ro  # For CO-RE eBPF
      - /data/capture:/data/capture          # Output directory
    environment:
      - CAPTURE_TARGET_PROCESS=cc-connect
      - OUTPUT_DIR=/data/capture
```

**Key detail**: The capture container shares PID and network namespace with the target. This means:
- tcpdump sees only the target's network traffic (no host-wide noise)
- eBPF can attach kprobes to the target process by PID
- The capture container can be garbage-collected independently

**Alternative: Host-level capture** (for forensic / retrospective):

```bash
# Run on the Docker host, not in a container
docker run --privileged \
  --pid host \
  --network host \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /data/capture:/data/capture \
  capture-agent:latest \
  --name cc-connect \
  --global  # capture all TLS connections, filter by feishu IP
```

### 4.3 Startup Sequence

```
1. Ensure kernel ≥ 5.10, BTF available
2. Start tcpdump in background:
     tcpdump -i any -w /data/capture/raw/feishu.pcap -C 500 \
       "host msg-frontier.feishu.cn or port 443"
3. Wait for target process to start (or attach to running process)
4. Detect TLS library:
     ebpf-key-extract --detect-only --pid $TARGET_PID
5. Load eBPF program with detected offsets
6. Attach kprobes and start collecting keys
7. Write keys to /data/capture/keys/feishu-SSLKEYLOG.log
8. On process exit: flush buffers, close files, stop tcpdump
9. Post-process: compress pcap with gzip, verify key ↔ pcap correlation
```

---

## 5. Output Analysis

### 5.1 What You See After Decryption

Once the pcap is decrypted, you get:

**TCP-level metrics** (from raw pcap, no key needed):
- Connection setup time (SYN → SYN-ACK)
- Round-trip time (per packet)
- Retransmission count and pattern
- TCP window size evolution
- Connection teardown (FIN/RST sequence)

**TLS-level metrics** (decrypted with keys):
- Handshake type sequence
- Cipher suite negotiated
- Certificate chain (if not session resumed)
- SNI (Server Name Indication)
- ALPN negotiation (h2, http/1.1, wss-specific)

**Application data** (fully decrypted WSS frames):
- WebSocket frame boundaries (binary/text opcode, masking, length)
- Frame payload content (feishu JSON messages)
- Frame timing (inter-frame gaps, burst patterns)
- Frame size distribution

### 5.2 Analysis Queries (tshark)

**WSS frame timeline**:

```bash
tshark -r feishu.pcap \
  -o tls.keylog_file:feishu-SSLKEYLOG.log \
  -Y "websocket" \
  -T fields \
  -e frame.number \
  -e frame.time_relative \
  -e websocket.opcode \
  -e websocket.length \
  -e tcp.stream
```

**Feishu application messages** (JSON payloads):

```bash
# Extract text content from WS frames, decode any gzip/deflate
tshark -r feishu.pcap \
  -o tls.keylog_file:feishu-SSLKEYLOG.log \
  -Y "websocket and websocket.opcode==1" \
  -T fields \
  -e websocket.payload.text \
  | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        obj = json.loads(line.strip())
        print(json.dumps(obj, indent=2))
    except:
        pass
"
```

**Latency heatmap data**:

```bash
# Compute inter-frame gaps per direction
tshark -r feishu.pcap \
  -o tls.keylog_file:feishu-SSLKEYLOG.log \
  -Y "tls.app_data" \
  -T fields \
  -e frame.time_relative \
  -e tcp.stream \
  -e tls.record.content_type \
  | awk '{if ($3==23) print $1, $2}'
```

### 5.3 ClickHouse Integration (Optional)

For long-running captures, pipe parsed data into ClickHouse:

```sql
CREATE TABLE cc.ws_pcap_frames (
    ts                  DateTime64(9),
    stream_id           UInt64,           -- tcp.stream (tshark connection ID)
    frame_num           UInt64,           -- pcap frame number
    direction           Enum8('c2s'=1, 's2c'=2),  -- client-to-server or vice versa
    tcp_seq             UInt32,
    tcp_ack             UInt32,
    tcp_window          UInt32,
    tls_content_type    UInt8,            -- 20=ChangeCipher, 21=Alert, 22=Handshake, 23=AppData
    tls_handshake_type  UInt8,            -- 1=ClientHello, 2=ServerHello, ...
    app_data_len        UInt32,
    app_data            String,           -- Decrypted payload (truncated to 64KB)
    rtt_us              UInt32,           -- Estimated RTT at this frame (from ts difference)
    retransmitted       UInt8
) ENGINE = MergeTree
ORDER BY (stream_id, frame_num)
TTL toDate(ts) + toIntervalDay(30);
```

This enables queries like:
```sql
SELECT count() as frames, sum(app_data_len) as bytes, max(rtt_us) as max_rtt
FROM cc.ws_pcap_frames
WHERE ts > now() - INTERVAL 1 HOUR
  AND retransmitted = 0;
```

---

## 6. Failure Modes and Mitigations

| Failure Mode | Likelihood | Impact | Mitigation |
|-------------|-----------|--------|------------|
| **TLS library structure offset mismatch** | High (library updates) | Keys not extracted | Probing phase with fallback heuristic; downloadable offset DB |
| **Go crypto/tls in-tree (static binary)** | Medium (Go targets) | OpenSSL kprobes miss | Hook `crypto/tls.(*Conn).handshakeClient` in Go runtime; use uprobes instead of kprobes |
| **Perf ring buffer overflow** | Low (at 540 frames/day) | Lost key events | Increase buffer size; add BPF_MAP_TYPE_RINGBUF with wakeup watermark |
| **tcpdump drops packets** | Low (at low volume) | Missing frames | Monitor `/proc/net/pcap/drops`; alert if >1% loss |
| **Key extracted after pcap rotation** | Low | Key file and pcap out of sync | Align rotation boundaries (every hour on the hour) |
| **TLS 1.3 early secrets** | Medium (TLS 1.3 only) | Can't decrypt 0-RTT data | Extract `CLIENT_EARLY_TRAFFIC_SECRET`; document 0-RTT penalty |
| **eBPF program load fails** | Low (older kernels) | No key extraction | Fall back to tcpdump-only mode (packet metadata only) |
| **Process restarts (new PID)** | Medium | Lost tracking | Watch `proc` for new instances; auto-attach on exec (BPF_PROG_TYPE_TRACING) |
| **SELinux / AppArmor blocking BPF** | Low (Docker hosts) | eBPF load denied | Document SELinux policy exemptions; fall back to proxy-only |

---

## 7. Comparison: eBPF+tcpdump vs MITM Proxy

| Dimension | MITM Proxy (`proxy-intercept.md`) | eBPF + tcpdump (this doc) |
|-----------|-----------------------------------|---------------------------|
| **Intrusion** | Modifies network path | Zero intrusion (observation only) |
| **Latency overhead** | <1ms (forwarding) | Zero (kernel-level, no packet modification) |
| **Frame visibility** | Full, structured | Full, after decryption |
| **Replay capability** | Built-in (replay-feishu) | Manual (replay from decrypted data) |
| **TCP-level metrics** | None (proxy handles WS only) | Full (retransmits, RTT, windowing) |
| **Deployment complexity** | Low (single binary) | Medium (eBPF + tcpdump + keys) |
| **Kernel requirements** | None | Linux 5.4+, BPF capabilities |
| **Security (TLS verify)** | Proxy verifies feishu certificate | No TLS modification (keys read from memory) |
| **Key management** | N/A (proxy terminates TLS) | Key file must be secured; contains master secrets |
| **CI/CD integration** | Easy (replay test suite) | Harder (requires pcap + key files) |
| **Incident forensics** | Requires pre-deployment | Can be deployed retroactively |
| **Scale limit** | Application-level (WS frames) | Kernel-level (packets per second) |

**Selection guide**:

| Use Case | Best Approach |
|----------|---------------|
| Day-to-day monitoring, replay testing | MITM Proxy |
| Incident forensics on unknown binary | eBPF + tcpdump |
| Cross-validation (verify proxy is correct) | Both simultaneously |
| Third-party container (cannot modify) | eBPF + tcpdump |
| Retroactive capture (deploy after problem starts) | eBPF + tcpdump |
| Performance debugging (TCP-level) | eBPF + tcpdump |
| Low-resource environment (no room for proxy sidecar) | tcpdump-only (metadata only) |

---

## 8. Implementation Plan

### Phase 0: Research (Week 1)

- [ ] Determine the TLS library used by the target (cc-connect: Go crypto/tls? or linked OpenSSL?)
- [ ] Document structure offsets for the identified library version
- [ ] POC: manually extract TLS keys via `/proc/<pid>/mem` + gdb (validates key extraction concept)
- [ ] POC: decrypt a pcap with extracted keys via tshark

### Phase 1: eBPF Key Extractor (Weeks 2-3)

- [ ] Write eBPF program for SSL_do_handshake kretprobe (Approach A)
- [ ] Write userspace collector in Go (using cilium/ebpf library)
- [ ] Implement library detection via `/proc/<pid>/maps`
- [ ] Build offset database for OpenSSL 1.1.1, 3.0.0, BoringSSL (2 versions)
- [ ] Implement probing phase with fallback heuristic
- [ ] Integration test: extract keys from a known target, verify decryption
- [ ] Write tcpdump wrapper script (start/stop/rotate)

### Phase 2: Go TLS Support (Week 3)

- [ ] Determine if target uses Go crypto/tls (static binary, no OpenSSL)
- [ ] If yes: write eBPF uprobe hooks for `crypto/tls.(*Conn).handshakeClient` and `handshakeServer`
- [ ] Go TLS structure offset detection (Go version dependent)
- [ ] Test: extract keys from Go binary, compare with SSLKEYLOGFILE from GODEBUG=sslkeylogfile=1

### Phase 3: Production Deployment (Week 4)

- [ ] Container image with capture-agent binary
- [ ] Docker Compose config for sidecar capture container
- [ ] Systemd unit for host-level capture (non-Docker)
- [ ] Key file rotation (hourly, align with pcap rotation)
- [ ] Integration test: capture + decrypt a real feishu session
- [ ] Monitor: capture success rate (# sessions decrypted / # sessions detected)

### Phase 4: Analysis Tooling (Week 5)

- [ ] Script to export pcap + keys → decrypted WSS frames as JSON
- [ ] ClickHouse schema for parsed frame data (if needed)
- [ ] Grafana panels for TCP-level metrics (RTT, retransmits)
- [ ] Grafana panels for decrypted WS frame metrics
- [ ] Alert: pcap drop rate >1%, key extraction rate <90%

### Phase 5: kTLS Support (Week 6, Optional)

- [ ] Write eBPF program for `tls_set_sw_offload` kprobe (Approach B)
- [ ] Test: capture from nginx/haproxy with kTLS offload
- [ ] Compare keys from kTLS route vs SSL_* kprobe route
- [ ] Documentation for kTLS-specific capture

---

## 9. Security Considerations

| Concern | Mitigation |
|---------|------------|
| **Master secret in key file** | Key file permissions 0600; directory only readable by capture-agent and root |
| **Key file exfiltration** | Key file never leaves the capture host; decryption happens on isolated analysis workstation |
| **eBPF reads arbitrary process memory** | eBPF targets only specific SSL_* functions; BPF verifier restricts memory access |
| **Privileged container** | CAP_BPF + CAP_SYS_ADMIN required; no other capabilities granted |
| **Key file retention** | 7-day retention (matches incident response SLA); auto-delete via tmpfiles.d |
| **Decrypted data handling** | Analysis output stored in ClickHouse with 30-day TTL; raw decrypted frames never persisted |
| **Process crash from eBPF** | eBPF programs validated by BPF verifier; cannot crash target process (memory reads only) |

**Key file protection**: The SSLKEYLOGFILE contains the master secret for every TLS session. With this file, anyone can decrypt the corresponding pcap. Treat it as sensitive as private keys:

```bash
# Permission
chmod 0600 /data/capture/keys/*.log
chown capture-agent:capture-agent /data/capture/keys/

# Retention
find /data/capture/keys/ -name '*.log' -mtime +7 -delete
find /data/capture/raw/ -name '*.pcap*' -mtime +7 -delete

# Audit logging (tamper-evident key access)
auditctl -w /data/capture/keys/ -p wa -k sslkeylogfile
```

---

## 10. Open Questions

| Question | Options | Needed From |
|----------|---------|-------------|
| Target TLS library: is cc-connect's TLS Go crypto/tls or linked OpenSSL? | (a) Go crypto/tls (static) (b) Linked BoringSSL (c) Linked OpenSSL | Verify cc-connect build process |
| Go version in use? (determines Go TLS structure layout) | 1.21, 1.22, 1.23 | Go binary version output |
| Kernel version on target hosts? | (a) 5.10 (b) 5.15 (c) 6.x | Check production hosts |
| Is BTF available on target kernels? | (a) Yes (CO-RE works) (b) No (need BTF file) | `ls /sys/kernel/btf/vmlinux` on target |
| Do we need kTLS support? | (a) No (all userspace TLS) (b) Yes (nginx/haproxy in path) | Check if there's a reverse proxy before cc-connect |
| Incident response SLA that needs retroactive capture? | (a) Yes: deploy preemptively on all feishu hosts (b) No: deploy on-demand | Ops team decision |
| Can we install BCC/bpftrace on target hosts? | (a) Yes (simplifies prototyping) (b) No (avoid extra deps) | System admin policy |

---

## 11. Technical Risks

| Risk | Severity | Probability | Mitigation |
|------|----------|-------------|------------|
| **Go TLS offsets change per minor version** | High | High | Use `GODEBUG=sslkeylogfile=1` as primary method for Go targets; eBPF as fallback only |
| **BSD-style license compatibility** | Low | Medium | Use Apache 2.0 libbpf; cilium/ebpf is Apache 2.0 |
| **BPF verifier rejects our program** | Medium | Low | Write simple kprobes (access args, read struct offsets, emit event); no loops or complex logic |
| **`bpf_probe_read` fails on swapped pages** | Low | Medium | The SSL struct is likely in active memory during handshake; retry logic on failure |
| **TLS 1.3 key schedule complexity** | Medium | Medium | TLS 1.3 derives multiple traffic secrets; need to extract all 4+ secrets per connection. See Appendix A. |
| **Total decryption failure rate** | Medium | Medium | Expect 95%+ success for known offsets; 70-80% for heuristic mode; document known failure modes |

---

## 12. Related Work

| Doc | Relation |
|-----|----------|
| `docs/infra/reviews/proxy-intercept.md` | Primary approach; this doc is the fallback |
| `docs/infra/reviews/feishu-delivery.md` | Uses captured data for delivery monitoring |
| `docs/infra/observability-design.md` | Overall observability architecture |
| `docs/infra/chat.md` | Feishu bot operational FAQ |

---

## 13. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Primary key extraction method | Approach A (SSL_* kprobes) | Covers 90%+ of targets; simpler than kTLS |
| TLS 1.3 support | Extract all 4+ traffic secrets | Incomplete secrets → partial decryption only |
| Userspace language | Go (cilium/ebpf) | Same stack as cc-connect; static binary; good perf ring buffer support |
| Offset database | Bundled JSON with auto-update | Avoids recompilation for new library versions |
| tcpdump output format | PCAPNG (default in modern tcpdump) | Wireshark-native; supports nanosecond timestamps |
| Key file format | NSS SSLKEYLOGFILE | Universal compatibility; Wireshark/tshark read it natively |
| Correlation key | Client random (32 bytes) | Visible in both pcap and SSL structure; used as key in SSLKEYLOGFILE format |
| Capture scope | Per-process (shared PID ns) | Forensics mode uses host-wide with IP filter |
| ClickHouse pipeline | Optional, not default | The primary value is offline analysis; CK is for operational dashboards |
| Go TLS fallback | GODEBUG=sslkeylogfile=1 | Simpler than eBPF for Go targets; environment variable approach (no eBPF needed) |

---

## Appendices

### A. TLS 1.3 Key Schedule

TLS 1.3 derives multiple secrets during the handshake. For full decryption, we need all of them:

```
PSK (Pre-Shared Key) or (EC)DHE shared secret
    │
    ▼
Early Secret ──► CLIENT_EARLY_TRAFFIC_SECRET  (0-RTT data)
    │
    ▼
Handshake Secret ──► CLIENT_HANDSHAKE_TRAFFIC_SECRET
                  ──► SERVER_HANDSHAKE_TRAFFIC_SECRET
    │
    ▼
Master Secret ──► CLIENT_TRAFFIC_SECRET_0  (application data from client)
              ──► SERVER_TRAFFIC_SECRET_0  (application data from server)
              ──► EXPORTER_SECRET          (post-handshake, for session tickets)
              ──► CLIENT_TRAFFIC_SECRET_1  (if client sends more after server)
              ──► SERVER_TRAFFIC_SECRET_1  (if server sends more after client)
```

In SSLKEYLOGFILE format:
```
CLIENT_HANDSHAKE_TRAFFIC_SECRET <client_random> <hex_secret>
SERVER_HANDSHAKE_TRAFFIC_SECRET <client_random> <hex_secret>
CLIENT_TRAFFIC_SECRET_0 <client_random> <hex_secret>
SERVER_TRAFFIC_SECRET_0 <client_random> <hex_secret>
EXPORTER_SECRET <client_random> <hex_secret>
```

For TLS 1.2, only one secret is needed:
```
CLIENT_RANDOM <client_random> <master_secret>
```

### B. Quick Start: Manual Key Extraction (No eBPF)

Before investing in eBPF, validate the approach works for your target with manual tools:

**For Go binaries (1.22+)**:

```bash
# Go 1.22+ has built-in SSLKEYLOGFILE support
GODEBUG=sslkeylogfile=/tmp/keys.log ./cc-connect
```

**For OpenSSL-linked binaries**:

```bash
# Use gdb to extract keys from a running process
# This proves the key is extractable before building eBPF
gdb -p 1234 -batch \
  -ex "set pagination off" \
  -ex "call SSL_SESSION_get_master_key(SSL_get_session(ssl_ptr), buf, 48)" \
  -ex "call SSL_get_client_random(ssl_ptr, buf, 32)" \
  -ex "quit"
```

**For any process (with strace)**:

```bash
# strace can't extract keys, but can show TLS library calls
strace -e trace=write,read -s 0 -p 1234 2>&1 | grep "tls\|SSL"
```

**Go GODEBUG approach (recommended first step)**:

Simply set `GODEBUG=sslkeylogfile=<path>` for Go 1.22+ targets. This is the easiest path and should be tried before eBPF. If the target is a Go binary with in-tree crypto/tls (which is likely for cc-connect and lark-cli), this single environment variable gives you the same SSLKEYLOGFILE without any eBPF complexity.

### C. BPF CO-RE (Compile Once, Run Everywhere)

To avoid recompiling the eBPF program for each kernel version, use CO-RE (BPF Type Format):

```bash
# Prerequisite: BTF information available
ls /sys/kernel/btf/vmlinux  # Should exist on 5.10+ with CONFIG_DEBUG_INFO_BTF=y

# Build once:
clang -target bpf -g -O2 -c tls_key_extractor.bpf.c \
  -o tls_key_extractor.bpf.o

# Run on any kernel 5.10+:
ebpf-key-extract --pid 1234 --bpf-prog tls_key_extractor.bpf.o
```

If `/sys/kernel/btf/vmlinux` does not exist, we provide a BTF file for the target kernel version:

```bash
# Download BTF for Ubuntu 22.04 (5.15) from:
# https://github.com/aquasecurity/btfhub/
ebpf-key-extract --pid 1234 \
  --bpf-prog tls_key_extractor.bpf.o \
  --btf /data/btf/ubuntu-22.04.btf
```

### D. Performance Overhead Measurements

Planned benchmarks before production deployment:

| Test | Expected Overhead | Measurement |
|------|-------------------|-------------|
| eBPF kprobe (empty handler) | <100ns per hit | ftrace timing |
| eBPF key extraction (full handler) | <1µs per handshake | BPF program execution time (built-in counter) |
| Userspace ring buffer read | <10µs per event | Poll latency |
| tcpdump on loopback | <5% CPU at 100 Mbps | `perf stat` during capture |
| tcpdump on physical NIC | <1% CPU at 100 Mbps | Same (kernel zero-copy with AF_PACKET) |

At feishu scale (~540 frames/day, ~6 frame exchanges per message), the overhead is negligible — you are more likely to be limited by clock granularity than by BPF processing time.

### E. Troubleshooting Guide

**Problem**: No keys extracted
```
Check:
  1. Is the target using OpenSSL/BoringSSL? `lsof -p <pid> | grep libssl`
  2. Is the kprobe attached? `cat /sys/kernel/debug/tracing/trace | grep tls_key_extractor`
  3. Is the perf ring buffer full? Check `bpftool map show` for drops
  4. Is the handshake completing? `ss -t -p` should show ESTABLISHED
```

**Problem**: Decryption fails in Wireshark
```
Check:
  1. Does the SSLKEYLOGFILE have entries for the pcap's client_random?
     `grep <client_random_hex> feishu-SSLKEYLOG.log`
  2. Is the pcap from the same time window as the key extraction?
  3. TLS 1.3: are all traffic secrets present (not just CLIENT_RANDOM)?
  4. Is there a TLS proxy or load balancer in front of the target?
```

**Problem**: tcpdump capturing too much noise
```
Improve filter:
  1. Use TCP port only: `tcpdump port 443`
  2. Use specific IPs: `tcpdump host <feishu_ip>`
  3. Use BPF filter on TLS record type: complex but possible
  4. Use `tcpdump -p` (no promiscuous mode) to reduce capture volume
```

---

> **Summary**: eBPF + tcpdump provides a zero-intrusion fallback for feishu TLS traffic interception. By extracting TLS session keys from the target process's memory via eBPF kprobes, we can decrypt the corresponding pcap captured by tcpdump. This approach trades deployment simplicity (proxy) for kernel-level observability (retransmits, RTT, zero-copy). It is the right choice for incident forensics, third-party container inspection, and cross-validation of the MITM proxy. The Go target is the easiest case — `GODEBUG=sslkeylogfile=1` works without any eBPF at all. The hardest case (kTLS offload with custom TLS library) may require weeks of additional research.

> ／人◕ ‿‿ ◕人＼
