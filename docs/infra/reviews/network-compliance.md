---
decision: 稍后做
---

# Network Policy Compliance Monitoring

**Date:** 2026-05-23
**Status:** Design proposal
**Prerequisite reading:** `docs/infra/observability-design.md` (existing monitoring stack),
`docs/infra/5min-patrol-guide.md` (patrol integration),
`docs/infra/reviews/sing-box-metrics.md` (sing-box traffic capture).

---

## 1. Problem

All infra containers share a flat bridge network (`kyb-net`) with **no native isolation**:

```
kyb-net (172.x.x.0/24)
    │
    ├── kyb-infra-postgresql-14    :5432
    ├── kyb-infra-postgresql-15    :5432
    ├── kyb-infra-postgresql-16    :5432
    ├── kyb-infra-postgresql-17    :5432
    ├── kyb-infra-redis            :6379
    ├── kyb-infra-clickhouse       :9000 :8123
    ├── kyb-infra-kafka            :9092
    ├── kyb-infra-grafana          :3000
    ├── kyb-infra-sing-box         :2080 :9090
    ├── kyb-infra-cc-connect       :(no fixed ports)
    ├── kyb-infra-boss             :(boss processes)
    ├── kyb-infra-boss2            :(boss processes)
    ├── kyb-infra-boss3            :(boss processes)
    ├── kyb-infra-boss-fallback    :(boss processes)
    ├── kyb-registry-cache         :5000 (host network)
    └── kyb-ubuntu-test            :(test container)
```

Docker bridge networks have no built-in network policies (unlike Kubernetes NetworkPolicies
or Calico). Any container on `kyb-net` can reach any other container on `kyb-net` by default.
There is no firewall, no iptables rules, and no nftables on the Orbstack host.

This creates several invisible risk modes:

| Risk | Scenario | Consequence |
|------|----------|-------------|
| **Lateral movement** | Compromised sandbox or test container probes PG/Redis | Data exfiltration, credential theft |
| **Unauthorized service access** | A boss container directly connects to CK HTTP port | Bypasses intended proxy/auth |
| **Unexpected listeners** | A container starts an unplanned TCP listener | Unmonitored attack surface |
| **Stale exposure** | A port exposed during dev never gets closed | Long-lived unmonitored endpoint |
| **Cross-cluster bleed** | Multi-cluster setup with bridged networks | Traffic leaks between clusters |

The goal is to make **every connection visible** and **every unauthorized attempt alertable**.

---

## 2. Current Architecture

### 2.1 Service Connectivity Matrix

The current known-good connectivity (allowlist):

| Source | Destination | Port | Protocol | Purpose | Authorized |
|--------|-------------|------|----------|---------|------------|
| `*-boss` | `kyb-infra-clickhouse` | 9000 | TCP | CK native protocol | Yes |
| `*-boss` | `kyb-infra-sing-box` | 2080 | TCP | SOCKS5 proxy | Yes |
| `*-boss` | `kyb-infra-postgresql-16` | 5432 | TCP | App DB (mig25) | Yes |
| `*-boss` | `kyb-infra-redis` | 6379 | TCP | Queue/state | Yes |
| `kyb-infra-cc-connect` | Claude API | 443 | TCP | Outbound HTTPS | Yes |
| `kyb-infra-cc-connect` | `kyb-infra-sing-box` | 2080 | TCP | SOCKS5 proxy | Yes |
| `*-boss` | External (GitHub/GitLab) | 443 | TCP | git/glab | Yes |
| `kyb-infra-grafana` | `kyb-infra-clickhouse` | 9000 | TCP | CK data source | Yes |
| `kyb-infra-grafana` | `kyb-infra-sing-box` | 2080 | TCP | SOCKS5 proxy | Yes |

Every source-destination pair NOT on this list is a **potential compliance violation**.

### 2.2 No Default Enforcement

Because Docker bridge networks are flat:

- No `iptables` rules exist on the host (Orbstack).
- No `nftables` ruleset on the host or in any container.
- Docker's inter-container communication (`--icc`) defaults to `true`.
- The only isolation is the `kyb-net` bridge itself: containers not on `kyb-net` cannot reach it.
- Within `kyb-net`, any container can connect to any port on any other container.

This makes **monitoring** the only viable enforcement mechanism for now. If enforcement
is needed later, options include:

- Docker `--icc=false` with `--link` allowlisting (container-level).
- eBPF-based tools (Cilium, Tetragon) for per-packet policy enforcement.
- Sidecar proxy per container (Envoy, Istio sidecar pattern).
- Host-level `nftables` rules on Linux hosts (non-Orbstack clusters like Aliyun).

---

## 3. Design Goals

1. **Visibility** — every TCP/UDP connection between containers on `kyb-net` is logged.
2. **Allowlist** — known-good connections are the baseline; everything else is suspicious.
3. **Detection** — unauthorized access attempts trigger alerts within 1 minute.
4. **Firewall hits** — any iptables/nftables deny log is captured and alertable.
5. **Historical** — connection logs stored in ClickHouse for post-hoc analysis.
6. **Dashboards** — Grafana panels for compliance posture, top violators, trends.
7. **Minimal overhead** — monitoring must not affect container throughput or latency.

---

## 4. Data Sources

### 4.1 Connection Tracking (Primary)

The primary source of connection visibility is **conntrack** data from the Docker bridge.

#### 4.1.1 conntrack Events via ct-dumper

A lightweight sidecar container (`kyb-net-monitor`) reads `/proc/net/nf_conntrack` on the
host (or uses `conntrack -E` via the Docker socket). For each connection event (NEW,
UPDATE, DESTROY) involving a `kyb-net` IP, it emits a structured log line:

```json
{
  "timestamp": "2026-05-23T10:30:00.123456Z",
  "event": "conntrack_destroy",
  "src_ip": "172.x.0.5",
  "src_port": 45123,
  "dst_ip": "172.x.0.10",
  "dst_port": 5432,
  "protocol": "tcp",
  "bytes_in": 4096,
  "bytes_out": 128,
  "packets_in": 12,
  "packets_out": 3,
  "src_container": "kyb-infra-boss",
  "dst_container": "kyb-infra-postgresql-16",
  "allowlist_match": "yes",
  "connection_duration_ms": 45200
}
```

**Options for capturing conntrack:**

| Method | Pros | Cons | Recommended |
|--------|------|------|-------------|
| `conntrack -E` | Real-time events, low overhead | Requires `nf_conntrack` kernel module on host | Orbstack host (has netfilter) |
| `/proc/net/nf_conntrack` poll | No binary needed, simple read | Polling interval, no event stream | Alternative |
| `docker events --filter network=kyb-net` | Container metadata, no netfilter | Only container lifecycle, not connections | Supplement, not primary |
| eBPF (Tetragon) | Full packet visibility, no conntrack dep | Complex setup, high overhead | Future |

**Recommended**: `conntrack -E` via a sidecar container with `--pid=host` and
`--cap-add NET_ADMIN` (or bind-mount `/proc/1/ns/net` and `/proc/net/`).

#### 4.1.2 Docker Event Stream (Supplement)

`docker events --filter type=network` provides:
- Container connect/disconnect from `kyb-net`.
- Container start/stop (network state changes).
- Port mapping changes.

This is used to maintain the **container inventory** (which IP belongs to which container)
so conntrack raw IPs can be resolved to container names.

#### 4.1.3 Sing-Box Connection Logs (Supplement)

Sing-box already emits JSON connection-close logs to stdout (see
`docs/infra/reviews/sing-box-metrics.md`). These capture **proxy-bound** traffic:
containers that route through `kyb-infra-sing-box:2080`.

For compliance, sing-box logs cover:
- Which container connected to which external destination via the proxy.
- Which outbound (Relay-JP1, Cursor-Auto, Direct) was selected.
- Connection duration, bytes transferred.

Sing-box logs do NOT cover:
- Direct container-to-container traffic within `kyb-net` (bypassing the proxy).
- Traffic that doesn't go through SOCKS5.

### 4.2 Firewall Rule Hits (Secondary)

On clusters with host-level firewalls (Aliyun, office NUC), `iptables` or `nftables` rules
can be instrumented. On Orbstack (no firewall), this section applies to future clusters.

#### 4.2.1 iptables LOG Target

Add logging rules before DROP/REJECT targets:

```bash
# Log all dropped packets on FORWARD chain (Docker bridge traffic)
iptables -A FORWARD -i kyb-net -j LOG \
  --log-prefix "KYB-NET-DROP: " \
  --log-level warning

# Per-service allowlist logging (log only non-matching)
iptables -A FORWARD -i kyb-net -d 172.x.0.10 -p tcp --dport 5432 \
  ! -s 172.x.0.0/24 -j LOG \
  --log-prefix "KYB-PG-UNAUTH: "
```

Logs are captured by Vector (filebeat/fluentd) and sent to ClickHouse.

#### 4.2.2 nftables Log Statement

For nftables-based clusters:

```bash
nft add rule inet filter forward iifname "kyb-net" log prefix "KYB-NFT-DROP: "
```

#### 4.2.3 Docker's IPTABLES_LOGGING

Docker manages its own iptables chains (`DOCKER`, `DOCKER-USER`). To log
Docker-originated drops without interfering with Docker's rules:

```bash
iptables -I DOCKER-USER 1 -j LOG --log-prefix "DOCKER-USER: "
```

### 4.3 Periodic Port Scanner (Integrity Check)

A cron-style scan runs every 5 minutes from a dedicated container, probing all
`kyb-net` IPs for:

- Open TCP ports (SYN scan to common ports: 22, 80, 443, 5432, 6379, 9000, 8123, 9092,
  3000, 2080, 5000).
- Unexpected listeners (TCP ports open on a container that shouldn't have them).
- New containers on `kyb-net` that are not in the allowlist.

**Scanner profile:**

| Parameter | Value |
|-----------|-------|
| Tool | `nmap` in a `--network=kyb-net` container |
| Interval | Every 5 minutes |
| Scan type | `-sT` (TCP connect scan), no ping |
| Target | `172.x.0.0/24` (kyb-net subnet) |
| Ports | Top 100 infra ports + dynamic range 1024-65535 weekly |
| Output | JSON to stdout -> Vector -> ClickHouse |

The scanner is itself a known entity on `kyb-net` and must appear in the allowlist.

---

## 5. ClickHouse Schema

### 5.1 Connection Log

```sql
CREATE DATABASE IF NOT EXISTS net;

CREATE TABLE net.connection_log (
    timestamp       DateTime64(6)   -- Nanosecond precision from conntrack
        DEFAULT now64(),
    event_type      String,          -- 'new', 'update', 'destroy'
    src_ip          IPv4,
    src_port        UInt16,
    dst_ip          IPv4,
    dst_port        UInt16,
    protocol        String,          -- 'tcp', 'udp'
    bytes_in        UInt64,
    bytes_out       UInt64,
    packets_in      UInt64,
    packets_out     UInt64,
    src_container   LowCardinality(String),  -- Resolved from Docker event stream
    dst_container   LowCardinality(String),
    allowlist_match Enum8('yes'=1, 'no'=0, 'unknown'=-1),
    connection_duration_ms UInt64,   -- Only on 'destroy' events
    cluster         LowCardinality(String),  -- 'mac-orbstack', 'aliyun', 'office'
    tags            Array(String)    -- e.g. ['suspicious', 'unauthorized', 'known-backup']
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, src_container, dst_container)
TTL timestamp + INTERVAL 90 DAY DELETE
SETTINGS index_granularity = 8192;
```

### 5.2 Port Scan Result

```sql
CREATE TABLE net.port_scan (
    timestamp       DateTime
        DEFAULT now(),
    scan_id         UUID,
    target_ip       IPv4,
    target_container LowCardinality(String),
    port            UInt16,
    protocol        String,          -- 'tcp', 'udp'
    state           String,          -- 'open', 'closed', 'filtered'
    service         String,          -- 'postgresql', 'redis', 'unknown'
    expected        Enum8('yes'=1, 'no'=0),  -- Is this port expected per allowlist?
    cluster         LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, target_container, port)
TTL timestamp + INTERVAL 90 DAY DELETE;
```

### 5.3 Container Inventory

```sql
CREATE TABLE net.container_inventory (
    timestamp       DateTime
        DEFAULT now(),
    container_name  LowCardinality(String),
    container_id    String,
    ip_address      IPv4,
    image           String,
    status          String,          -- 'running', 'stopped', 'exited'
    networks        Array(String),   -- e.g. ['kyb-net', 'bridge']
    ports           Array(Tuple(UInt16, String)),  -- (port, protocol)
    cluster         LowCardinality(String)
)
ENGINE = ReplacingMergeTree(timestamp)
ORDER BY container_name
SETTINGS index_granularity = 8192;
```

### 5.4 Allowlist

```sql
CREATE TABLE net.allowlist (
    updated_at      DateTime
        DEFAULT now(),
    source          LowCardinality(String),  -- container name or pattern (e.g. '*-boss')
    destination     LowCardinality(String),  -- container name or pattern
    port            UInt16,
    protocol        String,          -- 'tcp', 'udp'
    purpose         String,          -- human-readable reason
    enabled         UInt8 DEFAULT 1
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (source, destination, port);
```

### 5.5 Unauthorized Access Alert

```sql
CREATE TABLE net.unauthorized_access (
    timestamp       DateTime
        DEFAULT now(),
    src_container   LowCardinality(String),
    dst_container   LowCardinality(String),
    dst_port        UInt16,
    protocol        String,
    reason          String,          -- 'not_in_allowlist', 'blocked_by_firewall',
                                     -- 'unexpected_port', 'unexpected_container'
    first_seen      DateTime,
    last_seen       DateTime,
    occurrence_count UInt64,
    acknowledged    UInt8 DEFAULT 0,
    acknowledged_by String DEFAULT '',
    cluster         LowCardinality(String)
)
ENGINE = ReplacingMergeTree(timestamp)
ORDER BY (src_container, dst_container, dst_port);
```

### 5.6 Firewall Hit Log (future clusters)

```sql
CREATE TABLE net.firewall_hit (
    timestamp       DateTime64(3),
    source_ip       IPv4,
    dest_ip         IPv4,
    dest_port       UInt16,
    protocol        String,
    action          String,          -- 'DROP', 'REJECT', 'LOG'
    chain           String,          -- 'FORWARD', 'INPUT', 'DOCKER-USER'
    prefix          String,          -- log prefix from iptables LOG rule
    in_interface    String,          -- 'kyb-net', 'eth0'
    out_interface   String,
    src_container   LowCardinality(String),
    dst_container   LowCardinality(String),
    packet_len      UInt16,
    cluster         LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, chain, action)
TTL timestamp + INTERVAL 90 DAY DELETE;
```

---

## 6. Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  kyb-net (Docker bridge, 172.x.0.0/24)                                  │
│                                                                         │
│  ┌────────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐  │
│  │ kyb-infra-     │  │ kyb-infra-   │  │ kyb-net-     │  │ All      │  │
│  │ postgresql-16  │  │ clickhouse   │  │ monitor      │  │ others   │  │
│  │ :5432          │  │ :9000 :8123  │  │ (conntrack   │  │ on net   │  │
│  └────────────────┘  └──────────────┘  │  + scan)     │  └──────────┘  │
│                                         └──────┬───────┘               │
│  ┌────────────────┐  ┌──────────────┐         │                        │
│  │ kyb-infra-     │  │ kyb-infra-   │         │                        │
│  │ redis          │  │ sing-box     │         │                        │
│  │ :6379          │  │ :2080        │         │                        │
│  └────────────────┘  └──────────────┘         │                        │
│                                                │                        │
└────────────────────────────────────────────────┼────────────────────────┘
                                                 │
                    ┌────────────────────────────┼────────────────────┐
                    │  Vector container           │                    │
                    │  (log collector)            ▼                    │
                    │                             │                    │
                    │  ┌──────────────────────────────────────────┐   │
                    │  │  Input: docker logs (kyb-net-monitor)   │   │
                    │  │  Input: docker events (container state) │   │
                    │  │  Input: sing-box stdout (proxy traffic) │   │
                    │  │  Input: syslog (iptables logs, future)  │   │
                    │  │                                          │   │
                    │  │  Transform: resolve IP→container name   │   │
                    │  │  Transform: match vs. allowlist         │   │
                    │  │  Transform: tag suspicious connections  │   │
                    │  │                                          │   │
                    │  │  Sink: ClickHouse (net.* tables)        │   │
                    │  └──────────────────────────────────────────┘   │
                    └─────────────────────────────────────────────────┘
                                                 │
                                                 ▼
                    ┌─────────────────────────────────────────────────┐
                    │  Grafana                                         │
                    │  ┌──────────────────────────────────────────┐   │
                    │  │  Dashboard: Network Compliance Overview  │   │
                    │  │  Dashboard: Unauthorized Access Attempts │   │
                    │  │  Dashboard: Container Inventory          │   │
                    │  │  Dashboard: Firewall Hit Rate (future)   │   │
                    │  └──────────────────────────────────────────┘   │
                    └─────────────────────────────────────────────────┘
                                                 │
                                                 ▼
                    ┌─────────────────────────────────────────────────┐
                    │  Patrol (periodic health check)                  │
                    │  - Compare current container list vs. allowlist │
                    │  - Check scan results for unexpected ports     │
                    │  - Check unauthorized_access table for new rows│
                    │  - Report anomalies to Feishu                  │
                    └─────────────────────────────────────────────────┘
```

### 6.1 Components

| Component | Role | Deployment |
|-----------|------|------------|
| **kyb-net-monitor** | conntrack event listener + periodic port scanner | Sidecar on `kyb-net` |
| **Vector** | Log shipping, IP→container resolution, allowlist matching | Existing Vector container |
| **ClickHouse** | Storage for connection logs, scans, alerts | Existing `host.orb.internal:9000` |
| **Grafana** | Dashboards with CK data source | Existing infra Grafana |
| **Patrol** | Periodic compliance check, anomaly reporting | Existing patrol |

### 6.2 kyb-net-monitor Container

```bash
# Creation command
docker run -d \
  --name kyb-net-monitor \
  --network kyb-net \
  --pid=host \
  --cap-add NET_ADMIN \
  --cap-add SYS_PTRACE \
  -v /proc/net/:/host/proc/net/:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --restart unless-stopped \
  kyb-net-monitor:latest
```

The container image bundles:
- `conntrack` binary (or uses `/proc/net/nf_conntrack`)
- `nmap` (for port scanning)
- `jq` + `curl` (for structured output to CK HTTP endpoint)
- Small entrypoint script that:
  1. Starts conntrack listener in background
  2. Starts Docker event listener in background
  3. Runs port scan every 5 minutes via cron
  4. Outputs all events as JSON lines to stdout

---

## 7. Detection Rules

### 7.1 Connection Allowlist Enforcement

For every `conntrack_destroy` event, check the `net.allowlist` table:

**Match criteria:** `source` pattern matches `src_container`, `destination` pattern matches
`dst_container`, `port` matches `dst_port`.

**Outcome:**
- Match found -> `allowlist_match = 'yes'`, no alert.
- No match -> `allowlist_match = 'no'`, insert into `net.unauthorized_access`.

**Pattern matching:** Source/destination patterns support glob-style wildcards:
- `*-boss` matches `kyb-infra-boss`, `kyb-infra-boss2`, `kyb-infra-boss-fallback`.
- `*` matches any container (use sparingly, for known scanners like kyb-net-monitor).
- Exact name matches take priority over wildcards.

### 7.2 Unexpected Listener Detection

For each port scan result where `state = 'open'` AND `expected = 'no'`:

| Severity | Condition | Example |
|----------|-----------|---------|
| CRIT | Data port open on non-owner container | Postgres port 5432 open on kyb-infra-redis |
| WARN | Management port open unexpectedly | Port 3000 open on kyb-infra-postgresql-16 |
| INFO | High ephemeral port open | Port 51234 open on any container |

### 7.3 Rogue Container Detection

If a container appears on `kyb-net` that is NOT in the allowlist's source or destination
columns AND not in the explicit exemption list, it triggers:

```
WARN: Unknown container "kyb-unknown-xyz" detected on kyb-net
  - Image: ubuntu:24.04
  - IP: 172.x.0.99
  - Action: investigate and add to allowlist or remove
```

Exception list includes:
- `kyb-net-monitor` (the compliance scanner itself)
- Temporary test containers (`kyb-ubuntu-test`) with TTL tracking

### 7.4 Lateral Movement Detection

If a connection is detected from a container that has NEVER connected to the destination
before (first-seen), it is flagged as potential lateral movement:

```
CRIT: First-seen connection pattern
  - Source: kyb-infra-boss2 (previously only connected to CK:9000)
  - Destination: kyb-infra-postgresql-14 (first connection ever)
  - Port: 5432
  - This container has no business accessing PG-14
```

### 7.5 Firewall Hit Detection (future clusters)

For clusters with iptables/nftables, each DROP log line is:

```
CRIT: Firewall BLOCK
  - Source: 10.0.0.5 -> Destination: 172.x.0.10:5432
  - Chain: FORWARD, Action: DROP
  - Likely: unauthorized PG access attempt from outside kyb-net
```

### 7.6 Grace Period for New Containers

New containers get a 5-minute grace period before compliance checks apply. This prevents
false positives during container startup/initialization.

Implementation: The `net.container_inventory` table tracks `first_seen`. Compliance checks
skip containers with `first_seen < now() - INTERVAL 5 MINUTE`.

---

## 8. Grafana Dashboards

### 8.1 Network Compliance Overview

**Purpose:** At-a-glance compliance posture of `kyb-net`.

| Panel | Query | Visualization |
|-------|-------|---------------|
| Connections (24h) | `SELECT count() FROM net.connection_log WHERE timestamp > now() - INTERVAL 1 DAY` | Stat |
| Unauthorized (24h) | `SELECT count() FROM net.unauthorized_access WHERE timestamp > now() - INTERVAL 1 DAY AND acknowledged=0` | Stat + alert color |
| Compliant % | Ratio of allowlist_match='yes' / total connections | Gauge (0-100%) |
| Top talkers | `SELECT src_container, count() FROM ... GROUP BY src_container ORDER BY count() DESC LIMIT 10` | Bar chart |
| Allowlist hits vs misses | `SELECT allowlist_match, count() FROM ... GROUP BY allowlist_match` | Pie chart |

### 8.2 Unauthorized Access Attempts

**Purpose:** Investigate every unauthorized connection.

| Panel | Query | Visualization |
|-------|-------|---------------|
| Timeline | `SELECT timestamp, src_container, dst_container, dst_port FROM net.unauthorized_access WHERE acknowledged=0 ORDER BY timestamp` | Table with time filter |
| Source breakdown | `SELECT src_container, count() FROM ... GROUP BY src_container ORDER BY count() DESC` | Bar chart |
| Destination heatmap | `SELECT dst_container, dst_port, count() FROM ... GROUP BY dst_container, dst_port` | Heatmap |
| First-time connections | `SELECT timestamp, src_container, dst_container, dst_port FROM net.connection_log WHERE allowlist_match='no' ORDER BY timestamp DESC LIMIT 50` | Table |

### 8.3 Container Inventory

**Purpose:** Know what's running on `kyb-net`.

| Panel | Query | Visualization |
|-------|-------|---------------|
| Active containers | `SELECT container_name, ip_address, image, status FROM net.container_inventory WHERE status='running' AND has(networks, 'kyb-net')` | Table |
| Container timeline | `SELECT timestamp, count(DISTINCT container_name) FROM ... GROUP BY timestamp` | Time series |
| Image distribution | `SELECT image, count() FROM ... WHERE status='running' GROUP BY image` | Pie chart |

### 8.4 Firewall Hit Rate (future clusters)

| Panel | Query | Visualization |
|-------|-------|---------------|
| Drops over time | `SELECT toStartOfHour(timestamp), count() FROM net.firewall_hit WHERE action='DROP' GROUP BY ...` | Time series |
| Top source IPs | `SELECT source_ip, count() FROM ... GROUP BY source_ip ORDER BY count() DESC LIMIT 10` | Table |
| Top blocked ports | `SELECT dest_port, count() FROM ... GROUP BY dest_port ORDER BY count() DESC` | Bar chart |

---

## 9. Alerting Rules

### 9.1 Patrol Integration

Patrol checks the following every cycle (currently every 5 minutes):

```bash
# 1. Check for new unauthorized access events
$ curl -s "http://clickhouse:8123/?query=SELECT+count()+FROM+net.unauthorized_access+WHERE+acknowledged=0+AND+timestamp+>+now()-INTERVAL+5+MINUTE"
> 0  # OK
> >0  # ALERT — unauthorized access detected in last 5 minutes

# 2. Check for unknown containers
$ curl -s "http://clickhouse:8123/?query=SELECT+container_name+FROM+net.container_inventory+WHERE+...NOT+IN+allowlist"
> (empty)  # OK
> kyb-unknown-foo  # ALERT — rogue container on kyb-net

# 3. Check for unexpected open ports
$ curl -s "http://clickhouse:8123/?query=SELECT+count()+FROM+net.port_scan+WHERE+expected='no'+AND+state='open'+AND+timestamp+>+now()-INTERVAL+10+MINUTE"
> 0  # OK
> >0  # ALERT — unexpected port(s) open on container

# 4. Check scanner itself is running
$ docker ps --filter name=kyb-net-monitor --filter status=running -q
> (container ID)  # OK
> (empty)  # ALERT — compliance scanner is down
```

### 9.2 Alert Severity Matrix

| Alert | Severity | Condition | Action |
|-------|----------|-----------|--------|
| Unauthorized connection | P1 | New `net.unauthorized_access` row with `acknowledged=0` | Investigate immediately |
| Rogue container on kyb-net | P1 | Container on kyb-net not in allowlist | Identify and remove or add to allowlist |
| Unexpected open port (CRIT) | P1 | Data port (5432/6379/9000) open on unexpected container | Investigate service exposure |
| Unexpected open port (WARN) | P2 | Management port (3000/9090) open unexpectedly | Check if intentional |
| Compliance scanner down | P2 | `kyb-net-monitor` container not running | Restart monitor container |
| Unknown connection spike | P2 | 10x increase in `allowlist_match='no'` rate over 1h baseline | Possible scanning or compromise |
| First-seen lateral movement | P2 | Container connects to a destination it has never connected to before, AND allowlist says no | Investigate container behavior |
| Firewall drop spike (future) | P2 | 5x increase in `firewall_hit` rate over 1h | Check for external scanning |

### 9.3 Acknowledgment Workflow

When an unauthorized access is legit (e.g., a new service was added):

1. Acknowledge the alert in Grafana (click "Acknowledge" on the panel).
2. Update `net.allowlist` with the new authorized connection.
3. The alert will not fire again for the same source-destination-port combination.

```sql
-- Acknowledge all alerts for a specific source-destination pair
INSERT INTO net.unauthorized_access
  (timestamp, src_container, dst_container, dst_port, protocol, reason,
   first_seen, last_seen, occurrence_count, acknowledged, acknowledged_by)
VALUES
  (now(), 'kyb-infra-boss', 'kyb-infra-postgresql-14', 5432, 'tcp',
   'not_in_allowlist', now(), now(), 1, 1, 'boss');
```

---

## 10. Implementation Plan

### Phase 1: Container Inventory & Allowlist (Day 1)

1. Create `net.container_inventory` and `net.allowlist` tables in ClickHouse.
2. Deploy a Vector config that captures `docker events --filter type=network` and
   writes container state to CK.
3. Manually populate `net.allowlist` with the current known-good matrix (Section 2.1).
4. **Verify**: Grafana dashboard shows all running containers on `kyb-net`.

### Phase 2: Port Scanner (Day 2)

1. Build `kyb-net-monitor` container with nmap.
2. Schedule scans every 5 minutes.
3. Write scan results to `net.port_scan` via curl to CK HTTP endpoint.
4. **Verify**: Grafana dashboard shows open ports per container, flagged unexpected ones.

### Phase 3: Connection Tracking (Day 3-4)

1. Add conntrack listener to `kyb-net-monitor` container.
2. Implement IP-to-container resolution (via Docker events cache).
3. Implement allowlist matching in Vector transform or in a lightweight Go sidecar.
4. Write connection events to `net.connection_log`.
5. Write unauthorized events to `net.unauthorized_access`.
6. **Verify**: Real-time connection flow visible in Grafana.

### Phase 4: Alerting & Patrol (Day 5)

1. Add patrol checks for unauthorized access, rogue containers, unexpected ports.
2. Configure Grafana alert rules (or patrol-based notification to Feishu).
3. **Verify**: Intentional unauthorized connection (e.g., boss container probes PG-17)
   triggers Feishu alert within 1 minute.

### Phase 5: Firewall Integration (future cluster)

1. On Aliyun/NUC clusters, add iptables/nftables logging rules.
2. Configure Vector to read host syslog or `/var/log/kern.log`.
3. Write firewall hits to `net.firewall_hit`.
4. **Verify**: Firewall DROP events appear in Grafana.

---

## 11. Operational Notes

### 11.1 False Positive Management

**Expected false positives:**
- DNS lookups from containers to system-dns or cn-dns.
- Healthcheck pings between containers (Docker healthcheck).
- `kyb-net-monitor` itself connecting to all containers during port scan.
- Temporary connections during container startup (grace period covers this).

**Mitigation:** Add these to `net.allowlist` with pattern matching:
```sql
INSERT INTO net.allowlist (source, destination, port, protocol, purpose) VALUES
  ('*', 'kyb-net-monitor', 0, 'tcp', 'Port scanner probes all containers'),
  ('kyb-net-monitor', '*', 0, 'tcp', 'Port scanner probes all containers'),
  ('*', 'system-dns', 53, 'udp', 'Container DNS resolution');
```

### 11.2 Performance Impact

| Component | Impact | Mitigation |
|-----------|--------|------------|
| conntrack listener | Negligible (< 0.1 CPU core) | conntrack -E uses netlink, not polling |
| Port scanner | Spikes CPU during scan (5s every 5min) | Small container, limited port range |
| CK storage | ~100 MB/day for 100k connections/day | TTL 90 days, MergeTree compression |

### 11.3 Security of the Monitor Itself

The `kyb-net-monitor` container has elevated privileges (`NET_ADMIN`, `SYS_PTRACE`,
`pid=host`). To prevent it from becoming an attack vector:

- Run as non-root user inside the container (capabilities are fine, but drop `--privileged`).
- Use a minimal base image (Alpine with only conntrack+nmap+curl).
- Pin the image digest, not tag.
- Monitor the monitor: patrol checks that `kyb-net-monitor` is running.
- Separate network: `kyb-net-monitor` should be on `kyb-net` but also have a
  dedicated management network for out-of-band access if needed.

### 11.4 Multi-Cluster Support

Each cluster gets its own `kyb-net-monitor` instance. The `cluster` column in every
ClickHouse table distinguishes events from different clusters.

For the super-boss orchestrator:

```sql
SELECT cluster, count() AS violations
FROM net.unauthorized_access
WHERE acknowledged=0
GROUP BY cluster
ORDER BY violations DESC;
```

This enables cross-cluster compliance comparison and centralized alerting.

---

## 12. Future Enhancements

| Enhancement | Priority | Description |
|-------------|----------|-------------|
| eBPF-based enforcement | Low | Replace conntrack with Tetragon/Cilium for per-packet policy enforcement |
| Network policy DSL | Low | YAML-based policy language (like K8s NetworkPolicy) for kyb-net |
| Automated remediation | Low | Auto-disconnect rogue containers from kyb-net via Docker API |
| TLS fingerprinting | Medium | Capture JA3/JA3S hashes to detect protocol misuse |
| DNS query tracking | Medium | Log DNS queries from each container to detect exfiltration |
| Flow logs to S3 | Low | Archive raw connection logs to OSS/S3 for longer retention |
| Integration with incident response | Low | Auto-create GitLab issues for P0/P1 compliance violations |

---

/／人◕ ‿‿ ◕人＼
