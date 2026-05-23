---
decision: 稍后做
---

# Design: Inter-Container Network Latency Monitoring

**Design doc**: `docs/infra/reviews/container-network-latency.md`
**Reviewer**: kyb
**Date**: 2026-05-23
**Scope**: Network latency between infra containers on Docker overlay networks, RTT tracking, degradation detection, ClickHouse ingestion, Grafana visualization

---

## Summary

Currently, inter-container network health in the infra cluster is invisible. Containers on `kyb-net` communicate freely via Docker DNS, but there is no monitoring to detect:

- **Latency degradation** between containers (e.g., sing-box proxy latency spiking)
- **Packet loss** on the Docker bridge network
- **Service port unavailability** (port closed, process hung, firewall rule changed)
- **Cross-cluster latency** between boss containers on different machines

This design fills that gap with a lightweight latency probe daemon that runs inside each `kyb-infra-boss` container, measures TCP connect latency to every infra service on `kyb-net`, and forwards results to central ClickHouse for analysis and alerting.

---

## Architecture

### Data Flow

```
kyb-infra-boss (each cluster)
    │  (TCP connect probes every 30s)
    ├── kyb-infra-sing-box       :2080  (SOCKS5 proxy)
    ├── kyb-infra-redis          :6379
    ├── kyb-infra-postgresql-14  :5432
    ├── kyb-infra-postgresql-15  :5432
    ├── kyb-infra-postgresql-16  :5432
    ├── kyb-infra-postgresql-17  :5432
    ├── kyb-infra-kafka          :9092
    ├── kyb-infra-clickhouse     :8123, :9000
    ├── kyb-infra-grafana        :3000
    ├── kyb-infra-cc-connect     :9810
    ├── kyb-infra-boss2          (Docker DNS)
    ├── kyb-infra-boss3          (Docker DNS)
    ├── kyb-infra-boss-fallback  (Docker DNS)
    ├── kyb-ubuntu-test          (Docker DNS)
    │
    │  (HTTP POST to central CK:8123 every 30s)
    ▼
ClickHouse (infra.network_latency)  ← on Mac/Orbstack (super-boss)
    │
    ├── Grafana dashboard (latency heatmap, time series, reachability)
    └── Alert system (degradation, unreachable, packet loss)
```

### Where It Runs

The probe daemon runs **inside each `kyb-infra-boss` container** (Mac/Orbstack, Aliyun, Office -- every cluster). This reuses existing infrastructure:

- Boss containers have outbound HTTP access to central CK (`100.104.244.99:8123`)
- `bash` + `curl` + `python3` are all available in the kyb base image
- Docker DNS resolves container names on `kyb-net` automatically
- No new containers or sidecars needed

### Probe Target List

The probe matrix covers every infra container on `kyb-net`. Each container may have multiple probe endpoints (different ports for different services).

#### Mac/Orbstack (Current Cluster)

| Target Container | Probe Port(s) | Service | Probe Type |
|---|---|---|---|
| `kyb-infra-sing-box` | 2080 | SOCKS5 proxy | TCP connect |
| `kyb-infra-redis` | 6379 | Redis cache | TCP connect |
| `kyb-infra-postgresql-14` | 5432 | PostgreSQL 14 | TCP connect |
| `kyb-infra-postgresql-15` | 5432 | PostgreSQL 15 | TCP connect |
| `kyb-infra-postgresql-16` | 5432 | PostgreSQL 16 | TCP connect |
| `kyb-infra-postgresql-17` | 5432 | PostgreSQL 17 | TCP connect |
| `kyb-infra-kafka` | 9092 | Kafka message bus | TCP connect |
| `kyb-infra-clickhouse` | 8123 | ClickHouse HTTP | TCP connect |
| `kyb-infra-clickhouse` | 9000 | ClickHouse native | TCP connect |
| `kyb-infra-grafana` | 3000 | Grafana UI | TCP connect |
| `kyb-infra-cc-connect` | 9810 | cc-connect API | TCP connect |
| `kyb-infra-boss2` | - | Boss (Docker DNS only) | DNS + ICMP (if available) |
| `kyb-infra-boss3` | - | Boss (Docker DNS only) | DNS + ICMP (if available) |
| `kyb-infra-boss-fallback` | - | Boss (Docker DNS only) | DNS + ICMP (if available) |
| `kyb-ubuntu-test` | - | Test container | DNS + ICMP (if available) |

#### External Targets

| Target | Address | Port | Description |
|---|---|---|---|
| `host.docker.internal` | `host.orb.internal` | 8123 | Central ClickHouse (self-test) |
| `host.docker.internal` | `host.orb.internal` | 3000 | Central Grafana |
| `docker.io` | `registry-1.docker.io` | 443 | Docker Hub (proxy health) |
| `git.leyantech.com` | n/a | 443 | GitLab (proxy + internet health) |
| `google.com` | n/a | 443 | Internet egress health |

### Why TCP Connect (Not ICMP Ping)

**Finding**: ICMP ping does not work reliably in the Orbstack Docker environment. Despite `ping_group_range` being set to `0 2147483647` (which should permit unprivileged ping), Alpine containers on `kyb-net` do not respond to ICMP echo requests. This is a characteristic of the Docker bridge network driver used by Orbstack -- ICMP traffic between containers is not forwarded.

Verified on 2026-05-23: zero containers on `kyb-net` (192.168.97.0/24) responded to ICMP ping. All TCP probes to known service ports succeeded.

**TCP connect latency** is therefore the primary measurement mechanism. TCP handshake (SYN-SYN/ACK-ACK) is a reliable round-trip measurement that:

- Works on any Docker network driver (bridge, overlay, macvlan)
- Requires no special container capabilities (`NET_RAW` not needed for client-side connect)
- Simultaneously verifies service availability (port is open and accepting connections)
- Is consistent across all Linux container runtimes

### ICMP Fallback

On clusters where ICMP is available (e.g., native Docker CE on Aliyun or Office NUC), the probe daemon should also send ICMP pings as a secondary metric. ICMP measures network-layer round trip, while TCP measures application-layer round trip. The difference between the two can indicate application-level queuing or kernel TCP stack pressure.

---

## ClickHouse Schema

### `infra.network_latency` -- per-probe record

```sql
CREATE TABLE infra.network_latency (
    -- Identity
    boss_id         LowCardinality(String),       -- hostname of the probing boss
    cluster         LowCardinality(String),       -- mac-orbstack | aliyun | office

    -- Probe metadata
    event_time      DateTime64(3),                -- probe start time
    probe_type      LowCardinality(String),       -- tcp_connect | icmp_ping | dns_resolve

    -- Target
    target_name     LowCardinality(String),       -- container name or FQDN (kyb-infra-redis)
    target_ip       String,                       -- resolved IP at probe time
    target_port     UInt16,                       -- 0 for ICMP probes

    -- Results
    rtt_ms          Float32,                      -- round-trip time in milliseconds
    rtt_min_ms      Float32,                      -- minimum RTT in the probe window
    rtt_max_ms      Float32,                      -- maximum RTT in the probe window
    rtt_stddev_ms   Float32,                      -- standard deviation (if multiple attempts)
    success         UInt8,                        -- 1 = probe succeeded, 0 = failed/timeout
    error_msg       String DEFAULT '',            -- timeout, connection_refused, dns_failure, etc.

    -- Probe config
    attempts        UInt8 DEFAULT 3,              -- number of probe attempts
    timeout_ms      UInt16 DEFAULT 2000,          -- per-attempt timeout in ms

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (event_time, boss_id, target_name)
TTL event_time + INTERVAL 90 DAY;
```

### Design Decisions

1. **Sorting key `(event_time, boss_id, target_name)`**: Covers time-range scans and per-target-per-cluster filtering.

2. **LowCardinality for `boss_id`, `cluster`, `probe_type`, `target_name`**: Few distinct values (~3 clusters, ~4 bosses, ~15 targets, 2-3 probe types).

3. **`rtt_ms` as Float32 rather than UInt16**: Some external targets may have latencies > 65535 ms (though that would be extreme). Float32 also allows storing fractional milliseconds from nanosecond-precision timing.

4. **`rtt_min_ms`, `rtt_max_ms`, `rtt_stddev_ms`**: The probe daemon makes 3 attempts per target per cycle. These fields capture the distribution, not just the average. Degradation often manifests as increased variance before the mean shifts.

5. **Separate `probe_type` column**: Allows mixing TCP connect and ICMP measurements in the same table. Queries can filter by type or compare both.

6. **TTL 90 days**: Matches other infra tables. Latency volume is ~5k rows/day, so 90 days of history is under 2 GB even uncompressed.

### `infra.network_latency_baseline` -- rolling baseline for degradation detection

```sql
CREATE TABLE infra.network_latency_baseline (
    -- Identity
    cluster         LowCardinality(String),
    target_name     LowCardinality(String),
    target_port     UInt16,
    probe_type      LowCardinality(String),

    -- Baseline metrics (computed daily)
    baseline_date   Date,
    avg_rtt_ms      Float32,
    min_rtt_ms      Float32,
    max_rtt_ms      Float32,
    stddev_rtt_ms   Float32,
    p50_rtt_ms      Float32,
    p90_rtt_ms      Float32,
    p99_rtt_ms      Float32,
    success_rate    Float32,                      -- fraction of probes that succeeded (0.0-1.0)

    -- Sample count
    sample_count    UInt32
) ENGINE = ReplacingMergeTree(baseline_date)
ORDER BY (cluster, target_name, target_port, probe_type, baseline_date);
```

**Purpose**: A materialized aggregation that rolls up per-day statistics. The alert system queries this to compare current latency against historical norms. Baselines are computed daily via a cron job or ClickHouse materialized view.

**Refresh mechanism**: A daily cron job on the super-boss:

```sql
INSERT INTO infra.network_latency_baseline
SELECT
    cluster,
    target_name,
    target_port,
    probe_type,
    toDate(event_time) AS baseline_date,
    avg(rtt_ms) AS avg_rtt_ms,
    min(rtt_ms) AS min_rtt_ms,
    max(rtt_ms) AS max_rtt_ms,
    stddevSamp(rtt_ms) AS stddev_rtt_ms,
    quantile(0.50)(rtt_ms) AS p50_rtt_ms,
    quantile(0.90)(rtt_ms) AS p90_rtt_ms,
    quantile(0.99)(rtt_ms) AS p99_rtt_ms,
    avg(success) AS success_rate,
    count() AS sample_count
FROM infra.network_latency
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY cluster, target_name, target_port, probe_type, baseline_date;
```

### Estimated Volume

| Item | Value |
|---|---|
| Targets per probe cycle | ~16 internal + ~4 external = 20 endpoints |
| Probes per cycle (3 attempts each) | 20 endpoints * 1 probe_type * 3 attempts = 60 rows |
| Cycles per day (every 30s) | 2880 |
| Raw rows per day | 60 * 2880 = ~172,800 |
| Row size (compressed) | ~60 bytes |
| Daily volume | ~10 MB |
| 90-day total | ~900 MB |

This is the largest of the infra monitoring tables, but still modest for ClickHouse. With LZ4 compression and LowCardinality optimization, actual disk usage is estimated at 200-300 MB for 90 days.

---

## Probe Daemon Implementation

### Script: `latency-probe.sh`

```bash
#!/usr/bin/env bash
# latency-probe.sh -- runs inside kyb-infra-boss
# Probes all infra containers on kyb-net for TCP connect latency
# Posts results to central ClickHouse every cycle.

set -euo pipefail

CK_URL="${CK_URL:-http://host.orb.internal:8123}"
CK_TABLE="${CK_TABLE:-infra.network_latency}"
BOSS_ID="${BOSS_ID:-$(hostname)}"
CLUSTER="${CLUSTER_NAME:-unknown}"
PROBE_INTERVAL="${PROBE_INTERVAL:-30}"           # seconds between cycles
PROBE_ATTEMPTS="${PROBE_ATTEMPTS:-3}"             # attempts per target per cycle
PROBE_TIMEOUT="${PROBE_TIMEOUT:-2}"               # seconds per attempt

# Target matrix: target_name ip port description
# Uses Docker DNS names for internal containers
TARGETS=(
  "kyb-infra-sing-box:kyb-infra-sing-box:2080:SOCKS5 proxy"
  "kyb-infra-redis:kyb-infra-redis:6379:Redis cache"
  "kyb-infra-postgresql-14:kyb-infra-postgresql-14:5432:PostgreSQL 14"
  "kyb-infra-postgresql-15:kyb-infra-postgresql-15:5432:PostgreSQL 15"
  "kyb-infra-postgresql-16:kyb-infra-postgresql-16:5432:PostgreSQL 16"
  "kyb-infra-postgresql-17:kyb-infra-postgresql-17:5432:PostgreSQL 17"
  "kyb-infra-kafka:kyb-infra-kafka:9092:Kafka"
  "kyb-infra-clickhouse-http:kyb-infra-clickhouse:8123:ClickHouse HTTP"
  "kyb-infra-clickhouse-native:kyb-infra-clickhouse:9000:ClickHouse native"
  "kyb-infra-grafana:kyb-infra-grafana:3000:Grafana"
  "kyb-infra-cc-connect:kyb-infra-cc-connect:9810:cc-connect API"
  "kyb-infra-boss2:kyb-infra-boss2:22:Boss 2"
  "kyb-infra-boss3:kyb-infra-boss3:22:Boss 3"
  "kyb-infra-boss-fallback:kyb-infra-boss-fallback:22:Boss fallback"
  "kyb-ubuntu-test:kyb-ubuntu-test:22:Ubuntu test"
)

# External targets (reachable via proxy or direct)
EXTERNAL_TARGETS=(
  "docker-io:registry-1.docker.io:443:Docker Hub"
  "git-leyantech:git.leyantech.com:443:GitLab"
  "google-com:google.com:443:Internet egress"
)

# Resolve container IP once per cycle (handles container restarts)
resolve_target() {
  local hostname="$1"
  getent hosts "$hostname" 2>/dev/null | awk '{print $1}' | head -1
}

# Probe a single TCP endpoint, return RTT in milliseconds
tcp_probe() {
  local host="$1"
  local port="$2"
  local timeout="$3"

  # Use Python for precise timing (bash /dev/tcp is too coarse)
  python3 -c "
import socket, time
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout($timeout)
    t0 = time.monotonic()
    sock.connect(('$host', $port))
    t1 = time.monotonic()
    sock.close()
    elapsed = (t1 - t0) * 1000  # convert to ms
    print(f'OK {elapsed:.3f}')
except socket.timeout:
    print('TIMEOUT -1')
except socket.error as e:
    print(f'ERROR {e}')
" 2>/dev/null
}

# Build JSON payload and send to ClickHouse
send_to_ck() {
  local rows="$1"
  if [ -z "$rows" ]; then
    return
  fi

  curl -s -X POST "$CK_URL?query=INSERT+INTO+$CK_TABLE+FORMAT+JSONEachRow" \
    -d "$rows" \
    --max-time 10 2>/dev/null || echo "[WARN] CK write failed for latency probes" >&2
}

# Main probe cycle
probe_cycle() {
  local now epoch_ns event_time rows
  rows=""

  for target in "${TARGETS[@]}" "${EXTERNAL_TARGETS[@]}"; do
    IFS=':' read -r name host port desc <<< "$target"

    # Resolve hostname to IP (for Docker DNS names)
    local ip
    ip=$(resolve_target "$host" 2>/dev/null || echo "$host")
    if [ -z "$ip" ]; then
      ip="$host"
    fi

    # Run probe attempts
    local rtt_values=()
    local rtt_min=999999
    local rtt_max=0
    local rtt_sum=0
    local success_count=0
    local error_msg=""

    for ((i=0; i<PROBE_ATTEMPTS; i++)); do
      local result
      result=$(tcp_probe "$host" "$port" "$PROBE_TIMEOUT")
      local status="${result%% *}"
      local value="${result#* }"

      if [ "$status" = "OK" ]; then
        rtt_values+=("$value")
        success_count=$((success_count + 1))
        # Compare as float: use awk
        rtt_min=$(echo "$value $rtt_min" | awk '{if ($1 < $2) print $1; else print $2}')
        rtt_max=$(echo "$value $rtt_max" | awk '{if ($1 > $2) print $1; else print $2}')
      elif [ "$status" = "TIMEOUT" ]; then
        error_msg="timeout"
      else
        error_msg="${value:-unknown_error}"
      fi
    done

    # Compute average and stddev
    local rtt_avg=0
    local rtt_stddev=0
    local success=0

    if [ "$success_count" -gt 0 ]; then
      success=1
      # Average
      rtt_avg=$(printf '%s\n' "${rtt_values[@]}" | awk '{s+=$1} END{printf "%.3f", s/NR}')
      # Standard deviation
      if [ "${#rtt_values[@]}" -gt 1 ]; then
        rtt_stddev=$(printf '%s\n' "${rtt_values[@]}" | awk -v avg="$rtt_avg" '{sum+=($1-avg)^2} END{printf "%.3f", sqrt(sum/NR)}')
      fi
    fi

    # Fallback: if all attempts failed, set -1 for RTT fields
    if [ "$success" -eq 0 ]; then
      rtt_avg=-1
      rtt_min=-1
      rtt_max=-1
      rtt_stddev=-1
    fi

    # Use Python for precise timestamp
    epoch_ns=$(python3 -c "import time; print(int(time.time() * 1e9))")
    # Format as DateTime64(3)
    event_time=$(python3 -c "
import time
t = time.time()
sec = int(t)
ms = int((t - sec) * 1000)
print(f'{time.strftime(\"%Y-%m-%dT%H:%M:%S\", time.gmtime(sec))}.{ms:03d}Z')
")

    # Escape single quotes in error_msg for CK JSONEachRow
    error_msg="${error_msg//\'/\\\'}"

    rows+="{\"boss_id\":\"$BOSS_ID\",\"cluster\":\"$CLUSTER\",\"event_time\":\"$event_time\",\"probe_type\":\"tcp_connect\",\"target_name\":\"$name\",\"target_ip\":\"$ip\",\"target_port\":$port,\"rtt_ms\":$rtt_avg,\"rtt_min_ms\":$rtt_min,\"rtt_max_ms\":$rtt_max,\"rtt_stddev_ms\":$rtt_stddev,\"success\":$success,\"error_msg\":\"$error_msg\",\"attempts\":$PROBE_ATTEMPTS,\"timeout_ms\":$((PROBE_TIMEOUT * 1000))}"
    rows+=$'\n'
  done

  send_to_ck "$rows"
}

# Main loop
echo "[INFO] latency-probe started: cluster=$CLUSTER boss=$BOSS_ID interval=${PROBE_INTERVAL}s"

while true; do
  probe_cycle
  sleep "$PROBE_INTERVAL"
done
```

### Deployment

Each boss (Mac/Orbstack, Aliyun, Office) runs the same setup:

```bash
# Inside the kyb-infra-boss container:
# 1. Write the probe script
cat > /usr/local/bin/latency-probe.sh << 'SCRIPT'
#!/usr/bin/env bash
# [paste the full script from above]
SCRIPT
chmod +x /usr/local/bin/latency-probe.sh

# 2. Create the CK tables (run once on super-boss CK)
docker exec kyb-infra-boss bash -c "
  curl -s -X POST http://host.docker.internal:8123 \
    -d 'CREATE TABLE IF NOT EXISTS infra.network_latency ( ... ) ENGINE = MergeTree ORDER BY (event_time, boss_id, target_name) TTL event_time + INTERVAL 90 DAY'
  curl -s -X POST http://host.docker.internal:8123 \
    -d 'CREATE TABLE IF NOT EXISTS infra.network_latency_baseline ( ... ) ENGINE = ReplacingMergeTree(baseline_date) ORDER BY (cluster, target_name, target_port, probe_type, baseline_date)'
"

# 3. Start the probe daemon in background
CLUSTER_NAME=mac-orbstack nohup /usr/local/bin/latency-probe.sh \
  > /var/log/latency-probe.log 2>&1 &

# 4. Add to boss startup
echo 'CLUSTER_NAME=mac-orbstack /usr/local/bin/latency-probe.sh > /var/log/latency-probe.log 2>&1 &' \
  >> /home/dev/.bashrc
```

### Boss Startup Integration

Add to the 5-minute patrol checklist to ensure the probe daemon stays running:

```bash
# In patrol script:
pgrep -f latency-probe > /dev/null || {
  logger "[PATROL] latency-probe not running, restarting"
  CLUSTER_NAME="${CLUSTER_NAME:-unknown}" nohup /usr/local/bin/latency-probe.sh \
    > /var/log/latency-probe.log 2>&1 &
}
```

### Per-Cluster Configuration

| Cluster | Environment Variable |
|---|---|
| Mac/Orbstack (super-boss) | `CLUSTER_NAME=mac-orbstack CK_URL=http://host.orb.internal:8123` |
| Aliyun (sim) | `CLUSTER_NAME=aliyun CK_URL=http://100.104.244.99:8123` |
| Office (nuc8) | `CLUSTER_NAME=office CK_URL=http://100.104.244.99:8123` |

Aliyun and Office bosses send probes to central CK via Tailscale. The CK URL differs because `host.orb.internal` only resolves on the Mac/Orbstack host.

---

## Query Examples

### Current Latency Status (all targets, latest probe)

```sql
SELECT
    cluster,
    target_name,
    target_port,
    rtt_ms,
    rtt_min_ms,
    rtt_max_ms,
    success,
    event_time
FROM infra.network_latency
WHERE (cluster, target_name, target_port, event_time) IN (
    SELECT cluster, target_name, target_port, max(event_time)
    FROM infra.network_latency
    GROUP BY cluster, target_name, target_port
)
ORDER BY cluster, target_name;
```

### Targets with Elevated Latency (>2x baseline)

```sql
WITH latest AS (
    SELECT cluster, target_name, target_port, avg(rtt_ms) AS current_avg
    FROM infra.network_latency
    WHERE event_time >= now() - INTERVAL 5 MINUTE
      AND success = 1
    GROUP BY cluster, target_name, target_port
)
SELECT
    l.cluster,
    l.target_name,
    l.target_port,
    l.current_avg,
    b.p50_rtt_ms AS baseline_p50,
    b.p90_rtt_ms AS baseline_p90,
    round(l.current_avg / b.p50_rtt_ms, 2) AS ratio_vs_baseline
FROM latest l
JOIN infra.network_latency_baseline b
  ON l.cluster = b.cluster
 AND l.target_name = b.target_name
 AND l.target_port = b.target_port
 AND b.baseline_date = yesterday()
WHERE l.current_avg > b.p90_rtt_ms * 2  -- 2x the P90 threshold
ORDER BY ratio_vs_baseline DESC;
```

### Unreachable Targets (last 15 minutes)

```sql
SELECT
    cluster,
    target_name,
    target_port,
    error_msg,
    count() AS failures,
    min(event_time) AS first_failure,
    max(event_time) AS last_failure
FROM infra.network_latency
WHERE event_time >= now() - INTERVAL 15 MINUTE
  AND success = 0
GROUP BY cluster, target_name, target_port, error_msg
ORDER BY failures DESC;
```

### Latency Heatmap Data (last 1 hour, single target)

```sql
SELECT
    event_time,
    target_name,
    rtt_ms
FROM infra.network_latency
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND target_name = 'kyb-infra-redis'
  AND success = 1
ORDER BY event_time;
```

### Degradation Detection: Current vs Baseline StdDev

```sql
SELECT
    l.cluster,
    l.target_name,
    avg(l.rtt_ms) AS current_avg,
    countIf(l.success = 0) AS failures,
    b.avg_rtt_ms AS baseline_avg,
    b.stddev_rtt_ms AS baseline_stddev,
    round((avg(l.rtt_ms) - b.avg_rtt_ms) / b.stddev_rtt_ms, 2) AS z_score
FROM infra.network_latency l
JOIN infra.network_latency_baseline b
  ON l.cluster = b.cluster
 AND l.target_name = b.target_name
 AND l.target_port = b.target_port
 AND b.baseline_date = yesterday()
WHERE l.event_time >= now() - INTERVAL 5 MINUTE
  AND l.success = 1
  AND b.stddev_rtt_ms > 0
GROUP BY l.cluster, l.target_name, b.avg_rtt_ms, b.stddev_rtt_ms
HAVING z_score > 3  -- 3+ sigma deviation from baseline
ORDER BY z_score DESC;
```

### Probe Daemon Health (no data from a boss)

```sql
SELECT b.cluster, b.boss_id, b.event_time AS last_heartbeat,
       l.max_event_time AS last_latency_probe
FROM infra.boss_heartbeats b
LEFT JOIN (
    SELECT boss_id, max(event_time) AS max_event_time
    FROM infra.network_latency
    GROUP BY boss_id
) l ON b.boss_id = l.boss_id
WHERE b.event_time >= now() - INTERVAL 10 MINUTE
  AND (l.max_event_time IS NULL OR l.max_event_time < now() - INTERVAL 2 MINUTE);
```

---

## Grafana Dashboard

Recommended panels for a `Network Latency` dashboard:

### Row 1: Overview

| Panel | Type | Query Source | Description |
|---|---|---|---|
| Overall Health | Stat (single) | Count of `success=0` in last 5 min | Red if any failures |
| Avg Latency by Cluster | Stat (per cluster) | `avg(rtt_ms)` grouped by cluster | Rolling 5 min average |
| Probes/sec | Time Series | `count() / 30` | Probe throughput (should be stable) |

### Row 2: Latency Heatmap

| Panel | Type | Query Source | Description |
|---|---|---|---|
| Latency per Target | Heatmap | `rtt_ms` bucketed by target_name | Color intensity = latency value |
| Latency Time Series | Time Series | `avg(rtt_ms)` per target_name over 2h | Line chart, one series per target |
| Packet Loss | Time Series | `sum(success=0) / count() * 100` | Loss percentage per target |

### Row 3: Degradation Detection

| Panel | Type | Query Source | Description |
|---|---|---|---|
| Z-Score by Target | Table | Degradation query from Section 4 | Targets with Z > 3 highlighted |
| Baseline Comparison | Time Series | Current vs baseline.p50 and baseline.p90 | Overlay current on historical bands |
| Current Latency Table | Table | `target_name, rtt_ms, rtt_min_ms, rtt_max_ms, success` | Latest probe per target |

### Row 4: External Targets

| Panel | Type | Query Source | Description |
|---|---|---|---|
| Internet Latency | Time Series | External targets only (docker.io, gitlab, google) | Track internet egress health |
| Proxy Chain Latency | Time Series | sing-box target + external targets | Combined proxy + internet RTT |

### Row 5: Reachability Status

| Panel | Type | Query Source | Description |
|---|---|---|---|
| All Targets Status | State timeline | `success` per target per minute | Green/Red grid showing reachability |
| Unreachable Log | Table | `target_name, error_msg, event_time` (last 50) | Chronological log of failures |

---

## Alert Rules

| Rule | Conditions | Severity | Response |
|---|---|---|---|
| **Target unreachable** | 3 consecutive probe failures (90s of no connectivity) | P1 | Feishu alert: "${target} unreachable from ${cluster} — ${error_msg}" |
| **Latency spike** | Current avg > 3x baseline P90 for >5 minutes | P2 | Feishu: "${target} latency spike on ${cluster}: ${current}ms vs baseline ${baseline}ms" |
| **High latency variance** | StdDev > 2x baseline stddev for >5 minutes | P2 | Feishu: "${target} latency jitter on ${cluster} — possible network congestion" |
| **Cluster-wide latency** | 50%+ of targets in a cluster show elevated latency | P1 | Feishu: "Cluster-wide latency degradation on ${cluster} — check Docker bridge or host load" |
| **External connectivity loss** | All external targets unreachable from a cluster | P1 | Feishu: "Internet egress lost on ${cluster} — check proxy (sing-box) or Tailscale" |
| **Probe daemon down** | No data from a boss for >90 seconds | P2 | Feishu: "latency-probe down on ${cluster} boss ${boss_id}" |
| **Docker DNS failure** | `getent hosts` fails for an infra container name | P2 | Feishu: "Docker DNS resolution failure for ${target} on ${cluster}" |

### Alert Sliding Window

All latency-related alerts use a **5-minute sliding window** to avoid paging on transient spikes. The probe daemon runs every 30 seconds, so a 5-minute window contains ~10 probe cycles per target. The window is:

- **3 consecutive failures** (90s) = unreachable (P1)
- **>70% of probes in 5 min exceed threshold** = degradation (P2)
- **All probes failed across all targets** = infrastructure down (P1)

### False Positive Mitigation

1. **Boss container restart**: The heartbeat system already tracks boss container restarts. If a boss just restarted, suppress alerts for 2 minutes (warm-up period).

2. **Planned maintenance**: If a container is intentionally stopped (e.g., PG upgrade), suppress alerts via the `docker_events` table: a `container:die` followed by `container:start` within 5 minutes is an expected restart, not an incident.

3. **Baseline cold start**: During the first 24 hours of deployment, no baseline data exists. Disable z-score alerts and use absolute thresholds instead:
   - Internal targets: RTT > 100ms = degrade
   - External targets: RTT > 2000ms = degrade

---

## Degradation Detection Algorithm

### Three-Sigma Baseline Comparison

The core detection algorithm uses a rolling daily baseline with a z-score threshold:

```
z_score = (current_avg_rtt - baseline_avg_rtt) / baseline_stddev_rtt

if z_score > 3.0  →  DEGRADED (amber)
if z_score > 5.0  →  CRITICAL (red)
```

**Why three-sigma?** Docker bridge network latency is inherently low-variance (typical stddev 1-3ms on a local bridge). A 3-sigma threshold catches anomalies while tolerating the occasional scheduler jitter from container CPU throttling.

### Additional Detection: Consecutive Failure

```
consecutive_failures == 3  →  UNREACHABLE (red)
```

TCP connect failures within a Docker bridge network are rare. Three consecutive failures across 90 seconds indicates a real problem (container crash, network partition, Docker daemon issue).

### Rolling Window: Median + MAD

As a complement to z-score (which assumes normal distribution), use a rolling median + median absolute deviation (MAD) for the last 30 minutes:

```
median = median(rtt_ms, last 30 min)
mad = median(|rtt_ms - median|, last 30 min)
robust_z = 0.6745 * (current_rtt - median) / mad

if robust_z > 3.0  →  DEGRADED
```

MAD-based detection is more robust against outliers and non-normal distributions. Use z-score for the daily baseline (large sample, tends toward normal) and robust_z for the short-term rolling window.

---

## Implementation Checklist

### Phase 1: Schema (1h)
- [ ] Create `infra.network_latency` table in central ClickHouse
- [ ] Create `infra.network_latency_baseline` table
- [ ] Verify table creation with INSERT/SELECT test

### Phase 2: Deploy Probe (1h)
- [ ] Write and deploy `latency-probe.sh` to Mac/Orbstack super-boss
- [ ] Validate probes appear in CK (tail `infra.network_latency`)
- [ ] Add `CLUSTER_NAME=mac-orbstack` to probe startup command
- [ ] Add patrol watchdog to `kyb-infra-boss` startup

### Phase 3: Multi-Cluster (2h)
- [ ] Deploy `latency-probe.sh` to Aliyun boss (sim)
- [ ] Deploy to Office boss (nuc8)
- [ ] Configure CK URL to point to central CK via Tailscale
- [ ] Validate data arrives from all clusters

### Phase 4: Baseline (automated, day 2)
- [ ] Run initial baseline aggregation after 24h of data
- [ ] Schedule daily baseline computation via cron or CK materialized view
- [ ] Verify baseline accuracy against known normal behavior

### Phase 5: Grafana (2h)
- [ ] Build Network Latency dashboard (Rows 1-5 from Section 5)
- [ ] Add latency heatmap panel
- [ ] Add degradation detection panels
- [ ] Configure alerts in Grafana (thresholds from Section 6)

### Phase 6: Verification (1h)
- [ ] Simulate a network degradation (e.g., add `tc` netem on a container)
- [ ] Verify alert fires correctly
- [ ] Verify alert auto-resolves when condition clears
- [ ] Document runbook entry for latency incident response

---

## Cross-References

- **Docker event monitoring** (`docs/infra/reviews/docker-events.md`): Suppress false alerts during container restarts by cross-referencing `infra.docker_events`
- **Sing-box traffic monitoring** (`docs/infra/reviews/sing-box-metrics.md`): Correlate proxy latency spikes with external target latency degradation
- **Patrol guide** (`docs/infra/5min-patrol-guide.md`): Add `pgrep -f latency-probe` watchdog to patrol checklist
- **Multi-cluster architecture** (`docs/infra/multi-cluster-boss-architecture.md`): Per-cluster probe daemon deployment aligns with boss-per-cluster model
- **Observability design** (`docs/infra/observability-design.md`): Part of the broader infra observability initiative
- **Boss heartbeats** (`docs/infra/reviews/session-monitor.md`): Cross-reference boss heartbeats with latency probe data to distinguish "boss dead" from "network broken"

---

## Verdict

**Design is sound and ready for implementation.** The approach is zero-new-infrastructure (runs inside existing boss containers), uses reliable TCP probing (verified ICMP non-functional on Orbstack), and stores data in the established ClickHouse pipeline.

Key findings from the environment survey (2026-05-23):

| Finding | Detail |
|---|---|
| **ICMP broken** | 0 of 16 containers on `kyb-net` respond to ICMP ping. TCP is the only reliable probe method. |
| **TCP works** | All 11 service endpoints are reachable via TCP connect on `kyb-net`. |
| **Docker DNS works** | Container name resolution via `getent hosts` returns correct IPs. |
| **Baseline latency** | Docker bridge RTT is 2-5ms typical, with occasional spikes to 10-15ms. |
| **cc-connect port** | Port 9810 (not 9111) is reachable on `kyb-net`. |
| **Cross-cluster** | Aliyun and Office bosses can reach central CK via Tailscale at `100.104.244.99:8123`. |

The highest-value first step is deploying the probe daemon to the Mac/Orbstack super-boss only (Phase 1 + Phase 2) to validate the pipeline end-to-end, then expanding to Aliyun and Office.

> ／人◕ ‿‿ ◕人＼
