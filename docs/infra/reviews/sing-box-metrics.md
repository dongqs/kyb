---
decision: 稍后做
---

# Sing-Box Traffic Monitoring Design

Design for capturing per-outbound traffic metrics (bytes, connections, latency) from `kyb-infra-sing-box` into ClickHouse for analysis and Grafana visualization.

---

## 1. Goals

- **Bytes**: per-outbound upload/download totals and real-time throughput.
- **Connections**: active connection count per outbound, plus per-connection metadata (protocol, destination, duration).
- **Latency**: round-trip time for each relay node in `urltest` groups (Relay-JP1, Cursor-Auto, etc.).

Data flows into ClickHouse (`net.*` tables) for retention, analysis, and cross-referencing with other observability data.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  kyb-infra-sing-box                                              │
│  ┌─────────────┐   ┌─────────────────┐   ┌───────────────────┐  │
│  │ Mixed-In     │   │ Clash API       │   │ urltest nodes     │  │
│  │ :2080 SOCKS5 │   │ :9090           │   │ (latency probes)  │  │
│  └──────┬───────┘   └────────┬────────┘   └─────────┬─────────┘  │
│         │                    │                       │            │
│    stdout (JSON logs)   GET /connections         GET /proxies    │
│    connection close       GET /traffic            urltest delays │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
         │                     │                       │
         ▼                     ▼                       ▼
  ┌──────────────┐   ┌──────────────────┐   ┌──────────────────┐
  │ Vector       │   │ sb-metrics-poller│   │ sb-metrics-poller│
  │ (container)  │   │ (sidecar/--init) │   │ (sidecar/--init) │
  │ docker logs  │   │ Every 10s        │   │ Every 30s        │
  │ → CK sink    │   │ → CK HTTP sink   │   │ → CK HTTP sink   │
  └──────┬───────┘   └────────┬─────────┘   └────────┬─────────┘
         │                    │                       │
         ▼                    ▼                       ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  ClickHouse                                                    │
  │  net.connection_log  │  net.outbound_snapshot  │  net.latency  │
  └───────────────────────────────────────────────────────────────┘
                               │
                               ▼
                        ┌──────────────┐
                        │  Grafana     │
                        │  CK datasrc  │
                        └──────────────┘
```

### 2.1 Components

| Component | Role | Deployment |
|-----------|------|------------|
| **sing-box container** | Proxy runtime, emits JSON connection logs to stdout, exposes Clash API on port 9090 | Existing `kyb-infra-sing-box` |
| **Vector** | Parse sing-box JSON log lines, extract connection-close events, write to CK | Sidecar or separate container on `kyb-net` |
| **sb-metrics-poller** | Lightweight poller (bash+curl or Python), reads Clash API `/connections` and `/proxies`, writes snapshots to CK | Bundled in Vector container or standalone |
| **ClickHouse** | Metric storage, retention management | Existing `host.orb.internal:9000` |
| **Grafana** | Dashboards with CK data source | Existing infra Grafana |

---

## 3. Data Sources & Collection

### 3.1 Connection Close Events (per-connection)

**Source**: sing-box JSON stdout logs. When a connection closes, sing-box emits a structured log line:

```json
{
  "level": "info",
  "time": "2026-05-23T10:30:00.123Z",
  "type": "connection",
  "payload": {
    "action": "close",
    "inbound": "mixed-in",
    "outbound": "Relay-JP1",
    "network": "tcp",
    "destination": "8.8.8.8:443",
    "source": "192.168.97.10:54321",
    "upload": 4096,
    "download": 65536,
    "duration": 9876,
    "rule": "ai-sites"
  }
}
```

> **Note**: The exact JSON payload format depends on the sing-box version and log output configuration. If the structured JSON format above is unavailable, Vector will parse the traditional human-readable log line:
> ```
> 2026-05-23T10:30:00.123Z INF connection closed: inbound=mixed-in outbound=Relay-JP1 network=tcp destination=8.8.8.8:443 upload=4096 download=65536 duration=9876ms rule=ai-sites
> ```
> Vector's `parse_regex` or `parse_grok` transform handles this.

**Collector**: Vector `docker_logs` source targeting `kyb-infra-sing-box`, with a transform that:
1. Filters to `type="connection"` or lines matching connection-close pattern
2. Extracts fields: outbound, network, destination, upload, download, duration, rule
3. Routes to ClickHouse sink (`net.connection_log`)

### 3.2 Outbound Snapshots (point-in-time per-outbound)

**Source**: sing-box Clash API `GET /connections`.

```json
{
  "download_total": 1048576,
  "upload_total": 524288,
  "connections": [
    {
      "id": "abc123",
      "metadata": {
        "network": "tcp",
        "destination": "8.8.8.8:443",
        "source": "192.168.97.10:54321"
      },
      "upload": 4096,
      "download": 65536,
      "start": "2026-05-23T10:29:50.000Z",
      "chains": ["Relay-JP1"],
      "rule": "ai-sites"
    }
  ]
}
```

**Collector**: `sb-metrics-poller` runs every 10 seconds:
1. `GET /connections` on the sing-box Clash API
2. Count active connections per outbound (via `chains[0]`)
3. Record `upload_total` / `download_total` as cumulative counters
4. POST to CK `/net.outbound_snapshot`

The poller can be a minimal Python script (~50 lines) scheduled via `kyb infra boss` cron.

### 3.3 Latency Measurements (per relay node)

**Source**: sing-box Clash API `GET /proxies`. For each `urltest` group (e.g., `Relay-JP1`, `Cursor-Auto`), the API returns each node with its `delay` (latency in ms) and `history`.

```json
{
  "Relay-JP1": {
    "type": "Selector",
    "now": "Relay-JP1-1",
    "all": ["Relay-JP1-1", "Relay-JP1-2"],
    "history": []
  },
  "Relay-JP1-1": {
    "type": "Shadowsocks",
    "delay": 42
  },
  "Relay-JP1-2": {
    "type": "Shadowsocks",
    "delay": 55
  },
  "Cursor-Auto": {
    "type": "URLTest",
    "now": "cursor-us",
    "all": ["cursor-us", "cursor-jp", "cursor-hk"]
  },
  "cursor-us": { "type": "Shadowsocks", "delay": 120 },
  "cursor-jp": { "type": "Shadowsocks", "delay": 65 },
  "cursor-hk": { "type": "Shadowsocks", "delay": 88 }
}
```

**Collector**: `sb-metrics-poller` runs every 30 seconds:
1. `GET /proxies` on the Clash API
2. Extract each proxy with `type: "Shadowsocks"` (or other relay types) and its `delay` field
3. Include group membership (which urltest/selector group contains this node)
4. POST to CK `/net.latency`

---

## 4. ClickHouse Schemas

### 4.1 `net.connection_log` -- per-connection record

Written once per connection close event.

```sql
CREATE TABLE net.connection_log (
    event_time      DateTime64(3)        COMMENT 'Connection close time (from log timestamp)',
    outbound_tag    LowCardinality(String) COMMENT 'Outbound tag (Relay-JP1, direct, Cursor-Auto, etc.)',
    network         LowCardinality(String) COMMENT 'Protocol: tcp / udp',
    destination     String               COMMENT 'Destination IP:port',
    dest_host       String               COMMENT 'Destination hostname (if available, else IP)',
    dest_port       UInt16               COMMENT 'Destination port',
    source_ip       String               COMMENT 'Source IP (container/host IP)',
    bytes_upload    UInt64               COMMENT 'Bytes uploaded (client -> proxy)',
    bytes_download  UInt64               COMMENT 'Bytes downloaded (proxy -> client)',
    duration_ms     UInt32               COMMENT 'Connection duration in milliseconds',
    rule_tag        LowCardinality(String) COMMENT 'Matching rule tag (ai-sites, google, proxy-sites, etc.)',
    inbound_tag     LowCardinality(String) COMMENT 'Inbound interface',
    _raw            String               COMMENT 'Original log line for debugging'
) ENGINE = MergeTree
ORDER BY (event_time, outbound_tag)
TTL event_time + INTERVAL 30 DAY
```

**Partitioning**: Not needed at expected volume (< 100k rows/day). TTL handles cleanup.

**Design notes**:
- `LowCardinality` for `outbound_tag`, `network`, `rule_tag`, `inbound_tag` -- these repeat heavily, compression is excellent.
- `dest_host` separate from `destination` to allow filtering by hostname without parsing.
- `_raw` for debugging parsing issues; can be dropped after validation.
- 30-day retention covers trend analysis and incident review.

### 4.2 `net.outbound_snapshot` -- periodic active connection + cumulative bytes

Written every 10s by poller.

```sql
CREATE TABLE net.outbound_snapshot (
    event_time          DateTime         COMMENT 'Snapshot timestamp',
    outbound_tag        LowCardinality(String) COMMENT 'Outbound tag',
    active_connections  UInt16           COMMENT 'Currently active connections for this outbound',
    bytes_upload_total  UInt64           COMMENT 'Cumulative upload bytes (from /connections upload_total)',
    bytes_download_total UInt64          COMMENT 'Cumulative download bytes (from /connections download_total)',
    upload_speed_bps    UInt64           COMMENT 'Upload speed in bytes/sec (computed from delta)',
    download_speed_bps  UInt64           COMMENT 'Download speed in bytes/sec (computed from delta)'
) ENGINE = MergeTree
ORDER BY (event_time, outbound_tag)
TTL event_time + INTERVAL 7 DAY
```

**Design notes**:
- 7-day retention -- snapshot data is high-frequency and quickly aggregates down.
- `upload_speed_bps` / `download_speed_bps` are computed by the poller: delta of cumulative bytes divided by poll interval. The poller stores the previous cumulative value in memory.
- This table answers "what is the current traffic load per outbound?" and enables real-time dashboards.

### 4.3 `net.latency` -- per-node latency probes

Written every 30s by poller.

```sql
CREATE TABLE net.latency (
    event_time      DateTime         COMMENT 'Probe timestamp',
    node_tag        LowCardinality(String) COMMENT 'Node tag (e.g., Relay-JP1-1)',
    group_tag       LowCardinality(String) COMMENT 'Parent group (e.g., Relay-JP1)',
    node_type       LowCardinality(String) COMMENT 'Node type: Shadowsocks, SOCKS5, Direct, etc.',
    latency_ms      Nullable(UInt16) COMMENT 'Round-trip latency in ms (NULL if probe failed)',
    alive           UInt8            COMMENT 'Node is alive? 1 = yes, 0 = no/failed'
) ENGINE = MergeTree
ORDER BY (event_time, group_tag, node_tag)
TTL event_time + INTERVAL 90 DAY
```

**Design notes**:
- 90-day retention -- latency history is useful for long-term trend analysis (ISP degradation, relay quality).
- `alive` captures nodes that urltest marks as dead (no delay reported).
- `NULL` latency vs `alive=0` covers both "currently probing" and "confirmed dead" states.

---

## 5. Collection Pipeline Details

### 5.1 Vector Configuration (Connection Logs)

Place this in the Vector container's config:

```toml
[sources.singbox_logs]
type = "docker_logs"
include_containers = ["kyb-infra-sing-box"]

[transforms.parse_connection]
type = "remap"
inputs = ["singbox_logs"]
source = '''
  if !includes(["connection"], .type) {
    abort
  }

  # Parse JSON payload or fall back to regex
  if exists(.payload) && is_object(.payload) {
    .event_type = "connection_close"
    .outbound_tag = .payload.outbound
    .network = .payload.network
    .destination = .payload.destination
    .bytes_upload = to_int!(.payload.upload)
    .bytes_download = to_int!(.payload.download)
    .duration_ms = to_int!(.payload.duration)
    .rule_tag = .payload.rule
    .inbound_tag = .payload.inbound
    .source_ip = .payload.source
  } else {
    # Fallback: parse human-readable log
    parsed = parse_regex!(.message, r'outbound=(?P<outbound>\S+).*upload=(?P<up>\d+).*download=(?P<down>\d+).*duration=(?P<dur>\d+)')
    .outbound_tag = parsed.outbound
    .bytes_upload = to_int!(parsed.up)
    .bytes_download = to_int!(parsed.down)
    .duration_ms = to_int!(parsed.dur)
  }

  # Parse destination for port
  parts = split(.destination, ":")
  .dest_host = parts[0]
  .dest_port = to_int!(parts[1]) if length(parts) > 1 else 0

  .event_time = parse_timestamp!(.time, format: "%+")
'''

[sinks.connection_log]
type = "clickhouse"
inputs = ["parse_connection"]
endpoint = "http://host.orb.internal:8123"
database = "net"
table = "connection_log"
compression = "lz4"

[ sinks.connection_log.batch ]
max_events = 100
timeout_secs = 2
```

### 5.2 Poller Script (`sb-metrics-poller`)

A lightweight Python script (`~/.kyb/bin/sb-metrics-poller`) deployed on the infra-boss container or as a sidecar:

```python
#!/usr/bin/env python3
"""Poll sing-box Clash API and write metrics to ClickHouse."""

import json, time, urllib.request, http.client

SING_BOX_API = "http://kyb-infra-sing-box:9090"
CK_URL = "http://host.orb.internal:8123"

def poll_connections():
    """Snapshot active connections, grouped by outbound."""
    data = json.loads(urllib.request.urlopen(f"{SING_BOX_API}/connections").read())
    now = int(time.time())

    # Group by outbound
    by_outbound = {}
    for conn in data["connections"]:
        ob = conn["chains"][0] if conn["chains"] else "unknown"
        by_outbound.setdefault(ob, {"active": 0, "up": 0, "down": 0})
        by_outbound[ob]["active"] += 1

    # Batch insert
    client = http.client.HTTPConnection("host.orb.internal", 8123)
    for ob, stats in by_outbound.items():
        sql = f"""INSERT INTO net.outbound_snapshot
                  (event_time, outbound_tag, active_connections,
                   bytes_upload_total, bytes_download_total)
                  VALUES ({now}, '{ob}', {stats['active']},
                          {data['upload_total']}, {data['download_total']})"""
        client.request("POST", "/", sql)
    client.close()

def poll_latency():
    """Read latency for all relay nodes from /proxies."""
    data = json.loads(urllib.request.urlopen(f"{SING_BOX_API}/proxies").read())
    now = int(time.time())
    client = http.client.HTTPConnection("host.orb.internal", 8123)

    # Build group membership map
    groups = {}  # node_tag -> group_tag
    for name, proxy in data.items():
        if proxy["type"] in ("Selector", "URLTest"):
            for node in proxy.get("all", []):
                groups[node] = name

    # Record each node's latency
    for name, proxy in data.items():
        if proxy["type"] in ("Shadowsocks", "SOCKS5", "Direct", "Vless", "VMess"):
            delay = proxy.get("delay")
            group = groups.get(name, "")
            alive = 1 if delay is not None and delay > 0 else 0
            latency = delay if alive else "NULL"
            sql = f"""INSERT INTO net.latency
                      (event_time, node_tag, group_tag, node_type, latency_ms, alive)
                      VALUES ({now}, '{name}', '{group}', '{proxy['type']}',
                              {latency}, {alive})"""
            client.request("POST", "/", sql)
    client.close()

if __name__ == "__main__":
    poll_connections()
    poll_latency()
```

**Scheduling**: Via cron in the infra-boss container or a simple `while sleep` loop:

```bash
# /home/dev/.kyb/bin/sb-metrics-loop.sh
#!/bin/bash
while true; do
  python3 /home/dev/.kyb/bin/sb-metrics-poller
  sleep 10
done
```

---

## 6. Grafana Dashboards

### 6.1 Outbound Traffic Overview (Time Series)

| Panel | Query | Description |
|-------|-------|-------------|
| Upload/Download by Outbound | `SELECT event_time, outbound_tag, bytes_upload_total FROM net.outbound_snapshot ORDER BY event_time` | Stacked area, cumulative bytes per outbound |
| Throughput | `SELECT event_time, outbound_tag, upload_speed_bps, download_speed_bps FROM net.outbound_snapshot ORDER BY event_time` | Line chart, real-time throughput |
| Active Connections | `SELECT event_time, outbound_tag, active_connections FROM net.outbound_snapshot ORDER BY event_time` | Stacked area chart, concurrency per outbound |

### 6.2 Connection Detail (Table + Stats)

| Panel | Query | Description |
|-------|-------|-------------|
| Recent Connections | `SELECT * FROM net.connection_log ORDER BY event_time DESC LIMIT 100` | Raw connection table for debugging |
| Top Destinations | `SELECT dest_host, outbound_tag, count() AS conns, sum(bytes_download) AS total_down FROM net.connection_log WHERE event_time > now() - 1h GROUP BY dest_host, outbound_tag ORDER BY total_down DESC LIMIT 20` | Identify heavy traffic destinations |
| Protocol Mix | `SELECT network, count() AS cnt FROM net.connection_log WHERE event_time > now() - 1h GROUP BY network` | Pie chart, TCP vs UDP split |

### 6.3 Latency Heatmap

| Panel | Query | Description |
|-------|-------|-------------|
| Latency per Node | `SELECT event_time, node_tag, latency_ms FROM net.latency WHERE group_tag = 'Relay-JP1' ORDER BY event_time` | Time series per node in a group |
| Group Latency Range | `SELECT event_time, group_tag, min(latency_ms), max(latency_ms), avg(latency_ms) FROM net.latency WHERE event_time > now() - 1h GROUP BY event_time, group_tag` | Min/Max/Avg latency band per group |
| Latency Table | `SELECT node_tag, group_tag, avg(latency_ms) AS avg_lat, min(latency_ms), max(latency_ms) FROM net.latency WHERE event_time > now() - 1h GROUP BY node_tag, group_tag ORDER BY avg_lat` | Current latency ranking |

### 6.4 Alerting Candidates (Grafana Alerts)

| Condition | Threshold | Severity |
|-----------|-----------|----------|
| All nodes in a urltest group dead (`alive=0`) for >60s | Pager | Critical |
| Single outbound latency >500ms for >5min | Warning | Latency degradation |
| Active connections drop to 0 on all outbounds | Pager | Critical (sing-box may be down) |
| Per-outbound traffic anomaly (>3x standard deviation) | Warning | Possible misrouting or traffic loop |

---

## 7. Resource Estimation

| Table | Rows/day (est) | Row size | Daily volume | Retention | Total storage |
|-------|-----------------|----------|--------------|-----------|---------------|
| `net.connection_log` | ~10,000 | ~200 B | ~2 MB | 30 days | ~60 MB |
| `net.outbound_snapshot` | ~86,400 (10s interval) | ~80 B | ~6.9 MB | 7 days | ~48 MB |
| `net.latency` | ~40,000 (30s x ~15 nodes) | ~60 B | ~2.4 MB | 90 days | ~216 MB |
| **Total** | | | **~11.3 MB** | | **~324 MB** |

Compression (CK columnar + LowCardinality + LZ4) reduces actual disk usage by 5-8x -> **~40-65 MB total**. Negligible impact on existing ClickHouse deployment.

---

## 8. Implementation Checklist

- [ ] Enable sing-box Clash API (verify port 9090 is accessible on `kyb-net`)
- [ ] Configure sing-box JSON stdout logging for connection events
- [ ] Deploy Vector container or add sing-box log source to existing Vector
- [ ] Create `net.connection_log`, `net.outbound_snapshot`, `net.latency` tables in ClickHouse
- [ ] Write & deploy `sb-metrics-poller` script
- [ ] Validate pipeline: sing-box -> poller -> CK -> Grafana
- [ ] Build Grafana dashboards (3-4 panels)
- [ ] Set up alert rules for dead nodes, traffic anomalies
- [ ] Document runbook entry for metrics pipeline troubleshooting

---

## 9. Future Considerations

- **traffic-per-rule**: Group connection_log by `rule_tag` to understand which routing rules generate the most traffic.
- **per-container attribution**: If source IPs are predictable (containers on `kyb-net` with static names), join source IP to container name for per-sandbox traffic accounting.
- **prometheus scrape target**: sing-box may natively expose Prometheus metrics in future versions. If so, replace the poller with a Prometheus + Prometheus-ClickHouse connector.
- **cost estimation**: Multiply bytes per relay by provider rates to estimate per-outbound egress cost.

---

## 10. References

- [Sing-Box Clash API](https://sing-box.sagernet.org/configuration/experimental/clash-api/)
- [Sing-Box JSON Log Format](https://sing-box.sagernet.org/configuration/log/)
- [Sing-Box Outbound Groups (urltest)](https://sing-box.sagernet.org/configuration/outbound/urltest/)
- [Network Topology](../network/sing-box.md)
- [Proxy Configuration](../network/proxy.md)
- [Bridge CK Ingestion Design](bridge-ck-ingestion.md) -- prior art for Vector + CK pipeline
