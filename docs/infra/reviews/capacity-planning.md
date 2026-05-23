---
decision: 稍后做
---

# Capacity Planning Metrics

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Track resource growth per service, predict exhaustion dates, and recommend scaling actions across all clusters.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Service Resource Inventory](#2-service-resource-inventory)
3. [Metrics Definition](#3-metrics-definition)
4. [Growth Dimensions Per Service](#4-growth-dimensions-per-service)
5. [ClickHouse Schema](#5-clickhouse-schema)
6. [Collection Scripts](#6-collection-scripts)
7. [Exhaustion Prediction](#7-exhaustion-prediction)
8. [Scaling Recommendations](#8-scaling-recommendations)
9. [Grafana Dashboard](#9-grafana-dashboard)
10. [Alerting](#10-alerting)
11. [Cluster-Specific Profiles](#11-cluster-specific-profiles)
12. [Rollout Plan](#12-rollout-plan)

---

## 1. Problem Statement

The multi-cluster infrastructure has grown organically. Three clusters (Mac/Orbstack, Aliyun, Office) run 15+ services with no centralized view of resource growth trends. Key questions cannot be answered today:

| Question | Current answer |
|----------|---------------|
| Which service is growing disk the fastest? | Unknown -- no per-volume growth tracking |
| When will ClickHouse disk fill up? | Unknown -- ch-data is 278 MB today, but growth rate is not tracked |
| Is memory pressure increasing? | Heartbeats track mem_used_pct, but no per-service breakdown |
| Which boss container should be retired? | Cannot determine -- all 5 boss instances have similar names, different utilization |
| When will sim's 40 GiB disk exhaust? | Last known: not tracked -- disk-growth.md proposal not yet deployed |
| What is the network throughput trend? | Not tracked per service |

### What We Need

A capacity planning system that:

1. **Tracks per-service resource usage** -- CPU, memory (RSS), disk (volume + overlay), network I/O
2. **Computes growth rates** -- bytes/day, MB/week, %/month for each resource dimension
3. **Predicts exhaustion dates** -- linear projection per resource per service
4. **Recommends scaling actions** -- resource limits, cleanup, migration, retirement
5. **Alerts before exhaustion** -- with cluster-specific thresholds

---

## 2. Service Resource Inventory

### 2.1 Current Snapshot (Mac/Orbstack, 2026-05-23)

#### Containers Summary

| Service | CPU % | Memory (RSS) | Memory Limit | Disk (volume) | Overlay (est.) | Status |
|---------|-------|-------------|-------------|---------------|----------------|--------|
| kyb-infra-boss | 365.56% | 1.09 GiB | unlimited | 4.55 GB* | n/a | primary worker |
| kyb-infra-boss3 | 1.46% | 327 MiB | unlimited | 4.51 GB* | n/a | backup |
| kyb-infra-boss-fallback | 0.86% | 349 MiB | unlimited | 4.57 GB* | n/a | fallback |
| kyb-infra-boss2 | 0.00% | 50 MiB | 4 GiB | 333 MB* | n/a | snapshot (4 GB limit) |
| kyb-infra-boss-old | 2.91% | 439 MiB | unlimited | 8.37 GB* | n/a | old, likely stale |
| kyb-infra-cc-connect | 2.01% | 276 MiB | unlimited | 1 MB | n/a | message bridge |
| kyb-infra-clickhouse | 6.57% | 728 MiB | unlimited | 278 MB (volume) | n/a | analytics |
| kyb-infra-grafana | 7.29% | 264 MiB | unlimited | 84 MB (volume) | n/a | dashboards |
| kyb-infra-kafka | 2.94% | 475 MiB | unlimited | 11 MB (volume) | n/a | message queue |
| kyb-infra-postgresql-14 | 0.00% | 8 MiB | unlimited | 42 MB (volume) | n/a | legacy PG |
| kyb-infra-postgresql-15 | 0.00% | 30 MiB | unlimited | 81 MB (volume) | n/a | PG-15 |
| kyb-infra-postgresql-16 | 0.00% | 10 MiB | unlimited | 39 MB (volume) | n/a | PG-16 |
| kyb-infra-postgresql-17 | 0.00% | 11 MiB | unlimited | 39 MB (volume) | n/a | PG-17 |
| kyb-infra-redis | 0.64% | 7 MiB | unlimited | 12 KB (volume) | n/a | cache |
| kyb-infra-sing-box | 0.06% | 34 MiB | unlimited | 75 MB* | n/a | proxy |
| kyb-registry-cache | 0.00% | 8 MiB | unlimited | 188 KB (volume) | n/a | registry mirror |

*\* Container writable layer size (overlay2), not a named volume.*

#### Host Resources (Docker host)

| Resource | Total | Used | Available | Usage % |
|----------|-------|------|-----------|---------|
| Disk | 305 GiB | 84 GiB | 222 GiB | 28% |
| RAM | 15 GiB | 7.7 GiB | 7.9 GiB | 51% (with cache/buffer) |
| Swap | 16 GiB | 2.7 GiB | 13 GiB | 17% |
| CPU | 10 cores | N/A | N/A | N/A |

#### Named Volume Sizes

| Volume | Size | Service | Growth pattern |
|--------|------|---------|---------------|
| ch-data | 278 MB | ClickHouse | Slow, ~MB/day (cc.message_log ~34 KB/day) |
| grafana-storage | 84 MB | Grafana | Slow, grows with dashboards + alert history |
| kafka-data | 11 MB | Kafka | Minimal (no heavy usage yet) |
| pg15-data | 81 MB | PostgreSQL-15 | Stable (item_structure DB = 11 MB) |
| pg14-data | 42 MB | PostgreSQL-14 | Stable (no active databases > 9 MB) |
| pg16-data | 39 MB | PostgreSQL-16 | Stable |
| pg17-data | 39 MB | PostgreSQL-17 | Stable |
| kyb-gradle-cache | 4.1 GB | Build cache | Grows with CI/build frequency |
| kyb-maven-cache | 6.4 GB | Build cache | Grows with CI/build frequency |
| kyb-mise-cache | 381 MB | Runtime cache | Grows with tool version downloads |
| kyb-pip-cache | 337 MB | Package cache | Grows with Python dependency downloads |
| redis-data | 12 KB | Redis | Negligible (in-memory, persistence minimal) |
| cc-connect-data | 24 KB | cc-connect | Grows with session count |
| registry-cache | 188 KB | Registry | Grows with image pulls |

#### Docker Overhead

| Category | Size |
|----------|------|
| Images (total) | ~34 GiB (variable, includes build cache) |
| Containers (writable layers) | ~28 GiB (dominated by 5 boss instances) |
| Build cache | 21.79 GiB |
| Volumes | ~12 GiB (dominated by gradle + maven caches) |

### 2.2 Services Without Resource Limits

**Critical finding: 17 of 19 running containers have no memory limit, no CPU limit, and no OOM protection.** Only `kyb-infra-boss2` has a 4 GiB memory limit. This means:

- A memory leak in any container can exhaust host memory and cause OOM kills across the system.
- CPU starvation on the worker (kyb-infra-boss at 365%) can degrade cc-connect response times.
- No resource guarantees for stateful services (ClickHouse, PostgreSQL, Kafka).

---

## 3. Metrics Definition

### 3.1 Metric Categories

| Category | Metrics | Collection interval | Retention |
|----------|---------|-------------------|-----------|
| **Container CPU** | cpu_usage_pct, cpu_delta_ns, cpu_throttled_ns | 60s | 180 days |
| **Container Memory** | mem_rss_bytes, mem_cache_bytes, mem_swap_bytes, mem_limit_bytes, mem_usage_pct | 60s | 180 days |
| **Container Disk (volume)** | volume_used_bytes, volume_capacity_bytes | 300s | 180 days |
| **Container Disk (overlay)** | overlay_bytes, container_size_bytes | 300s | 180 days |
| **Container Network** | net_rx_bytes, net_tx_bytes, net_rx_packets, net_tx_packets | 300s | 180 days |
| **Host Disk** | total_bytes, used_bytes, avail_bytes, used_pct, inode_used_pct | 300s | 180 days |
| **Host Memory** | mem_total_bytes, mem_used_bytes, mem_avail_bytes, mem_used_pct, swap_used_bytes | 60s | 180 days |
| **Host CPU** | cpu_load_1m, cpu_load_5m, cpu_load_15m, cpu_count | 60s | 180 days |
| **Volume Growth** | volume_name, service_name, used_bytes, growth_bytes_per_day | 3600s (hourly) | 365 days |
| **Image Storage** | image_count, image_total_bytes, unused_image_bytes, dangling_bytes | 3600s | 180 days |
| **Build Cache** | cache_total_bytes, cache_active_bytes | 3600s | 180 days |

### 3.2 Per-Service Metric Dimensions

Every metric is tagged with these dimensions for filtering and aggregation:

| Dimension | Type | Example | Purpose |
|-----------|------|---------|---------|
| cluster | LowCardinality(String) | `mac-orbstack` | Multi-cluster filtering |
| service | LowCardinality(String) | `clickhouse` | Friendly service name |
| container_id | String | `sha256:abc...` | Docker container identity |
| container_name | String | `kyb-infra-clickhouse` | Docker container name |
| image | String | `clickhouse/clickhouse-server:24.2-alpine` | Image identification |
| mount_point | LowCardinality(String) | `/var/lib/clickhouse` | Volume mount path |

### 3.3 Derived Metrics (Computed Downstream)

| Metric | Formula | Purpose |
|--------|---------|---------|
| daily_growth_bytes | linear_regression(used_bytes, time) over 14d window | Predict exhaustion |
| days_until_full | (capacity - used) / daily_growth_bytes | Exhaustion countdown |
| growth_acceleration | delta(daily_growth_bytes) over 7d window | Detect runaway growth |
| mem_headroom | mem_limit - mem_rss_bytes | OOM risk indicator |
| cpu_headroom | 100 - cpu_usage_pct (average over 5min) | CPU saturation risk |
| volume_fragmentation | volume_used_bytes / (overlay_bytes + volume_bytes) | Storage efficiency |

---

## 4. Growth Dimensions Per Service

### 4.1 Service Growth Profile Table

Each service has different growth drivers. The metrics system must track the right dimension for each:

| Service | Primary growth dimension | Secondary growth | Typical growth rate | Acceleration risk |
|---------|-------------------------|-----------------|-------------------|-------------------|
| ClickHouse (ch-data) | Volume (data ingestion) | Memory (queries) | ~34 KB/day (cc.message_log) | Low -- message volume is stable |
| Grafana (grafana-storage) | Volume (dashboards, alert history) | Memory (dashboards) | ~1-5 MB/day | Low -- grows with dashboard count |
| Kafka (kafka-data) | Volume (message retention) | Memory (broker heap) | <1 MB/day | Low -- no heavy usage |
| PostgreSQL-15 (pg15-data) | Volume (database growth) | Memory (shared_buffers) | <1 MB/day | Low -- stable DBs |
| PostgreSQL-14/16/17 | Volume (database growth) | Memory (connections) | <1 MB/day | Low |
| Redis (redis-data) | Memory (keyspace) | Volume (RDB/AOF) | Negligible | Low |
| cc-connect | Memory (session state) | Volume (session files) | ~1-5 MB/week | Medium -- leaks possible |
| Boss containers (each) | Overlay (container writable layer) | Memory (Claude sessions) | ~100-500 MB/day | **High** -- boss containers grow with conversation history |
| kyb-infra-boss-old | Overlay | -- | 8.37 GB (candidate for cleanup) | N/A -- stale |
| kyb-gradle-cache | Volume (dependency cache) | -- | ~50-200 MB/week | Medium -- grows with project count |
| kyb-maven-cache | Volume (dependency cache) | -- | ~50-200 MB/week | Medium |
| Host disk (overall) | Docker images + build cache + container overlays | -- | ~200 MB - 1 GB/day | **High** -- build cache is unmanaged |
| Docker build cache | Build artifacts | -- | ~2-5 GB/week | **High** -- grows with CI frequency |

### 4.2 Critical Growth Vectors

Ordered by urgency (highest risk first):

1. **Boss container overlays** -- Each boss container grows over time as Claude code agents accumulate session state, conversation history, and git clones. The primary worker (kyb-infra-boss) is at 4.55 GB after 6 hours. At this rate, a boss container could reach 10+ GB in 24 hours. **5 boss containers means potentially 20-50 GB of overlay data.**

2. **Docker build cache** -- 21.79 GB unmanaged. Grows with every `kyb build` or Docker build. No TTL or pruning schedule.

3. **kyb-infra-boss-old** -- 8.37 GB container writable layer. Not running but consuming disk. No reason to keep.

4. **kyb-maven-cache / kyb-gradle-cache** -- Cumulative 10.5 GB across two volume caches. Grows with CI.

5. **Docker image sprawl** -- 37 images, many stale (e.g., PeerDB 0.35.0 from 6 months ago, Alpine 3.17 from 20 months ago, multiple click-rest CR images).

6. **Multiple boss instances** -- 5 boss instances, but only one is actively working (kyb-infra-boss at 365% CPU). The others are idle or near-idle, consuming ~4.5 GB of disk each for no operational benefit.

---

## 5. ClickHouse Schema

### 5.1 Container Resource Metrics (Raw)

```sql
CREATE TABLE infra.container_metrics (
    cluster             LowCardinality(String),
    service             LowCardinality(String),
    container_id        String,
    container_name      String,
    image               String,
    timestamp           DateTime64(3),

    -- CPU
    cpu_usage_pct       Float32,
    cpu_delta_ns        UInt64,
    cpu_throttled_ns    UInt64,
    cpu_count           UInt8 DEFAULT 0,

    -- Memory
    mem_rss_bytes       UInt64,
    mem_cache_bytes     UInt64,
    mem_swap_bytes      UInt64,
    mem_limit_bytes     UInt64,
    mem_usage_pct       Float32,

    -- Network (cumulative since container start)
    net_rx_bytes        UInt64,
    net_tx_bytes        UInt64,
    net_rx_packets      UInt64,
    net_tx_packets      UInt64,

    -- Disk I/O (cumulative since container start)
    blk_read_bytes      UInt64,
    blk_write_bytes     UInt64,

    -- Container disk
    container_size_bytes    UInt64,
    container_overlay_bytes UInt64,

    -- Status
    container_status    LowCardinality(String) DEFAULT 'running',
    restart_count       UInt32 DEFAULT 0
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (cluster, service, timestamp)
TTL timestamp + INTERVAL 180 DAY
```

### 5.2 Host Metrics (Raw)

```sql
CREATE TABLE infra.host_metrics (
    cluster             LowCardinality(String),
    hostname            String,
    timestamp           DateTime64(3),

    -- Disk (per mount point)
    mount_point         LowCardinality(String),
    fs_type             LowCardinality(String),
    total_bytes         UInt64,
    used_bytes          UInt64,
    avail_bytes         UInt64,
    used_pct            Float32,
    inode_used_pct      Float32,

    -- Memory
    mem_total_bytes     UInt64,
    mem_used_bytes      UInt64,
    mem_avail_bytes     UInt64,
    mem_used_pct        Float32,
    swap_total_bytes    UInt64,
    swap_used_bytes     UInt64,
    swap_used_pct       Float32,

    -- CPU
    cpu_count           UInt8,
    load_1m             Float32,
    load_5m             Float32,
    load_15m            Float32,

    -- Docker system
    container_running   UInt16,
    container_stopped   UInt16,
    container_total     UInt16,
    image_count         UInt16,
    image_total_bytes   UInt64,
    build_cache_bytes   UInt64,
    volume_count        UInt16,
    volume_total_bytes  UInt64,

    -- Network
    net_rx_bytes_total  UInt64,
    net_tx_bytes_total  UInt64
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (cluster, timestamp, mount_point)
TTL timestamp + INTERVAL 365 DAY
```

### 5.3 Volume Metrics (Per-Volume Growth Tracking)

```sql
CREATE TABLE infra.volume_metrics (
    cluster             LowCardinality(String),
    service             LowCardinality(String),
    volume_name         LowCardinality(String),
    mount_point         String,
    timestamp           DateTime64(3),

    used_bytes          UInt64,
    capacity_bytes      UInt64,
    file_count          UInt32,
    used_pct            Float32,

    -- Docker volume driver metadata
    driver              LowCardinality(String) DEFAULT 'local',
    options             String DEFAULT ''
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (cluster, volume_name, timestamp)
TTL timestamp + INTERVAL 365 DAY
```

### 5.4 Daily Growth Rollup (Materialized View)

```sql
CREATE MATERIALIZED VIEW infra.capacity_daily_mv
ENGINE = SummingMergeTree
ORDER BY (cluster, service, date)
POPULATE
AS
SELECT
    cluster,
    service,
    toDate(timestamp) AS date,

    -- Container memory (end-of-day)
    argMax(mem_rss_bytes, timestamp) AS mem_rss_eod,
    argMax(mem_limit_bytes, timestamp) AS mem_limit_eod,
    argMax(mem_usage_pct, timestamp) AS mem_usage_pct_eod,
    avg(mem_usage_pct) AS mem_usage_pct_avg,
    max(mem_usage_pct) AS mem_usage_pct_max,

    -- Container CPU (average/max)
    avg(cpu_usage_pct) AS cpu_usage_pct_avg,
    max(cpu_usage_pct) AS cpu_usage_pct_max,

    -- Container disk (end-of-day)
    argMax(container_size_bytes, timestamp) AS container_size_eod,
    argMax(container_overlay_bytes, timestamp) AS container_overlay_eod,

    -- Network (total delta for the day)
    max(net_rx_bytes) - min(net_rx_bytes) AS net_rx_daily,
    max(net_tx_bytes) - min(net_tx_bytes) AS net_tx_daily,

    -- Disk I/O daily
    max(blk_write_bytes) - min(blk_write_bytes) AS blk_write_daily,

    -- Sample count (data quality check)
    count() AS sample_count
FROM infra.container_metrics
GROUP BY cluster, service, date;
```

### 5.5 Capacity Projection Table (Updated Hourly)

```sql
CREATE TABLE infra.capacity_projections (
    cluster             LowCardinality(String),
    service             LowCardinality(String),
    dimension           LowCardinality(String),
        -- 'mem_rss' | 'volume_used' | 'container_overlay' | 'host_disk' | 'build_cache'
    computed_at         DateTime64(3) DEFAULT now(),
    current_value       Float64,
    capacity            Float64,
    used_pct            Float32,
    daily_growth        Float64,
    daily_growth_pct    Float32,
    days_until_full     Float64,
    exhaustion_date     Date,
    confidence          LowCardinality(String) DEFAULT 'low',
    slope               Float64,       -- linear regression slope
    intercept           Float64,       -- linear regression intercept
    r_squared           Float32,       -- goodness of fit
    data_points         UInt16,        -- number of data points used
    warning             Bool DEFAULT false,
    critical            Bool DEFAULT false
) ENGINE = ReplacingMergeTree
ORDER BY (cluster, service, dimension);
```

---

## 6. Collection Scripts

### 6.1 Container Metrics Collector

Deployed to each cluster boss. Runs on a 60-second loop.

```bash
#!/bin/bash
# collect-container-metrics.sh -- Send container resource metrics to ClickHouse
# Runs every 60s via boss heartbeat loop.

set -euo pipefail

CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"
CLUSTER="${CLUSTER:-unknown}"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
HOSTNAME=$(hostname)

# Get container stats from Docker
docker stats --no-stream --format '{
  "container_name": "{{.Name}}",
  "cpu_pct": {{.CPUPerc | trimSuffix "%"}},
  "mem_rss": {{.MemUsage | regexFind "^[0-9.]+" | trimSuffix "MiB" | multiply 1048576}},
  "mem_limit": {{.MemLimit | regexFind "^[0-9.]+" | trimSuffix "GiB" | multiply 1073741824}},
  "mem_pct": {{.MemPerc}},
  "net_rx": {{.NetIO | regexFind "^[0-9.]+"}},
  "net_tx": {{.NetIO | regexFind "[0-9.]+$"}},
  "blk_read": {{.BlockIO | regexFind "^[0-9.]+"}},
  "blk_write": {{.BlockIO | regexFind "[0-9.]+$"}}
}' | while read -r line; do
  # Map container name to service name
  CONTAINER_NAME=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['container_name'])")
  SERVICE=$(echo "$CONTAINER_NAME" | sed 's/^kyb-infra-//')
  IMAGE=$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}}' 2>/dev/null || echo "unknown")

  curl -s -X POST "$CK_HOST" \
    -H "Content-Type: text/plain" \
    --data-binary "INSERT INTO infra.container_metrics FORMAT JSONEachRow
$line"
done
```

### 6.2 Host Metrics Collector

```bash
#!/bin/bash
# collect-host-metrics.sh -- Send host-level metrics to ClickHouse
# Runs every 60s.

CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"
CLUSTER="${CLUSTER:-unknown}"
HOSTNAME=$(hostname)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

# --- Disk (all mount points) ---
DISK_JSON=$(python3 -c "
import subprocess, json
result = subprocess.run(['df', '--block-size=1', '--output=target,size,used,avail,pcent,ipcent,fstype'], capture_output=True, text=True, check=False)
lines = result.stdout.strip().split('\n')[1:]  # skip header
mounts = []
for line in lines:
    parts = line.split()
    if len(parts) >= 6 and parts[0].startswith('/'):
        pct = parts[3].rstrip('%')
        inode = parts[4].rstrip('%')
        mounts.append({
            'mount_point': parts[0],
            'total_bytes': int(parts[1]),
            'used_bytes': int(parts[2]),
            'avail_bytes': int(parts[3]),
            'used_pct': float(pct),
            'inode_used_pct': float(inode),
            'fs_type': parts[5]
        })
print(json.dumps(mounts))
")

# --- Memory ---
MEM_JSON=$(python3 -c "
import json
with open('/proc/meminfo') as f:
    mem = {}
    for line in f:
        parts = line.split(':')
        if parts[0] in ('MemTotal', 'MemFree', 'MemAvailable', 'SwapTotal', 'SwapFree', 'Cached'):
            val = parts[1].strip().split()[0]
            mem[parts[0]] = int(val) * 1024

used = mem['MemTotal'] - mem['MemFree'] - mem.get('Cached', 0)
avail = mem.get('MemAvailable', mem['MemFree'])
swap_used = mem.get('SwapTotal', 0) - mem.get('SwapFree', 0)
swap_total = mem.get('SwapTotal', 0)
print(json.dumps({
    'mem_total_bytes': mem['MemTotal'],
    'mem_used_bytes': used,
    'mem_avail_bytes': avail,
    'mem_used_pct': round(used / mem['MemTotal'] * 100, 1),
    'swap_total_bytes': swap_total,
    'swap_used_bytes': swap_used,
    'swap_used_pct': round(swap_used / swap_total * 100, 1) if swap_total > 0 else 0.0
}))
")

# --- CPU Load ---
LOAD_JSON=$(python3 -c "
import json
with open('/proc/loadavg') as f:
    parts = f.read().strip().split()
print(json.dumps({
    'load_1m': float(parts[0]),
    'load_5m': float(parts[1]),
    'load_15m': float(parts[2]),
    'cpu_count': $(nproc)
}))
")

# --- Docker System Info ---
DOCKER_JSON=$(python3 -c "
import subprocess, json
try:
    running = subprocess.run(['docker', 'ps', '-q'], capture_output=True, text=True).stdout.count('\n')
    total = subprocess.run(['docker', 'ps', '-aq'], capture_output=True, text=True).stdout.count('\n')
    images = subprocess.run(['docker', 'images', '-q'], capture_output=True, text=True).stdout.count('\n')

    # image sizes
    img_data = subprocess.run(['docker', 'system', 'df', '--format', '{{.Type}}\t{{.Size}}'], capture_output=True, text=True).stdout
    img_bytes = 0
    for line in img_data.split('\n'):
        if 'Images' in line:
            size_str = line.split('\t')[1]
            # parse '34GB', '12MB' etc.
            break

    print(json.dumps({
        'container_running': running,
        'container_total': total,
        'image_count': images,
        'volume_count': len(subprocess.run(['docker', 'volume', 'ls', '-q'], capture_output=True, text=True).stdout.strip().split('\n'))
    }))
except Exception as e:
    print(json.dumps({'error': str(e)}))
")

# Combine and send
python3 -c "
import json
data = {
    'cluster': '$CLUSTER',
    'hostname': '$HOSTNAME',
    'timestamp': '$TIMESTAMP',
    'mount_point': '/',
    'fs_type': 'overlay',
    **json.loads('''$MEM_JSON'''),
    **json.loads('''$LOAD_JSON'''),
    **json.loads('''$DOCKER_JSON''')
}
print(json.dumps(data))
" | curl -s -X POST "$CK_HOST" \
  -H "Content-Type: text/plain" \
  --data-binary "INSERT INTO infra.host_metrics FORMAT JSONEachRow
$(cat -)"
```

### 6.3 Volume Metrics Collector (Hourly)

```bash
#!/bin/bash
# collect-volume-metrics.sh -- Send Docker volume sizes to ClickHouse
# Runs every hour.

CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"
CLUSTER="${CLUSTER:-unknown}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

docker volume ls -q | while read -r vol; do
  mountpoint=$(docker volume inspect "$vol" --format '{{.Mountpoint}}')
  size=$(du -sb "$mountpoint" 2>/dev/null | cut -f1 || echo 0)
  file_count=$(find "$mountpoint" -type f 2>/dev/null | wc -l || echo 0)

  # Map volume name to service
  service="unknown"
  case "$vol" in
    ch-data) service="clickhouse" ;;
    grafana-storage) service="grafana" ;;
    kafka-data) service="kafka" ;;
    pg14-data) service="postgresql-14" ;;
    pg15-data) service="postgresql-15" ;;
    pg16-data) service="postgresql-16" ;;
    pg17-data) service="postgresql-17" ;;
    redis-data) service="redis" ;;
    cc-connect-data) service="cc-connect" ;;
    registry-cache) service="registry-cache" ;;
    kyb-*-cache) service="build-cache" ;;
  esac

  curl -s -X POST "$CK_HOST" \
    -H "Content-Type: text/plain" \
    --data-binary "INSERT INTO infra.volume_metrics FORMAT JSONEachRow
{
  \"cluster\": \"$CLUSTER\",
  \"service\": \"$service\",
  \"volume_name\": \"$vol\",
  \"mount_point\": \"$mountpoint\",
  \"timestamp\": \"$TIMESTAMP\",
  \"used_bytes\": $size,
  \"capacity_bytes\": 0,
  \"file_count\": $file_count,
  \"used_pct\": 0.0
}"
done
```

### 6.4 Deployment

Add these collectors to the heartbeat loop on each boss (or as cc-connect cron jobs on the super-boss).

---

## 7. Exhaustion Prediction

### 7.1 SQL Prediction Query

```sql
WITH
    -- Gather last 14 days of daily data per service per dimension
    recent AS (
        SELECT
            cluster,
            service,
            date,
            toUnixTimestamp(date) / 86400 AS day_num,
            mem_rss_eod AS value
        FROM infra.capacity_daily_mv
        WHERE date >= today() - 14
    ),
    -- Linear regression per (cluster, service)
    regression AS (
        SELECT
            cluster,
            service,
            count() AS n,
            sum(day_num * value) AS sum_xy,
            sum(day_num) AS sum_x,
            sum(value) AS sum_y,
            sum(day_num * day_num) AS sum_xx,
            sum(value * value) AS sum_yy,
            argMax(value, day_num) AS current_value,
            (n * sum(day_num * value) - sum(day_num) * sum(value))
                / (n * sum(day_num * day_num) - sum(day_num) * sum(day_num))
                AS slope,
            (sum(value) - slope * sum(day_num)) / n AS intercept
        FROM recent
        GROUP BY cluster, service
        HAVING n >= 3  -- minimum data points
    ),
    -- Compute R-squared and confidence
    stats AS (
        SELECT
            *,
            -- Pearson correlation coefficient
            (n * sum_xy - sum_x * sum_y) / sqrt(
                (n * sum_xx - sum_x * sum_x) * (n * sum_yy - sum_y * sum_y)
            ) AS r,
            CASE
                WHEN slope <= 0 THEN -1
                ELSE (capacity - current_value) / slope
            END AS days_until_full_
        FROM regression
    )
SELECT
    cluster,
    service,
    current_value,
    CASE
        WHEN days_until_full_ < 0 THEN NULL
        ELSE toDate(today() + toInt64(days_until_full_))
    END AS exhaustion_date,
    days_until_full_,
    slope AS daily_growth,
    r * r AS r_squared,
    n AS data_points,
    CASE
        WHEN n < 7 THEN 'low'
        WHEN r * r < 0.3 THEN 'low'
        WHEN r * r < 0.6 THEN 'medium'
        ELSE 'high'
    END AS confidence
FROM stats
```

### 7.2 Predicted Growth by Service (Current Estimates)

Based on current data and observed patterns:

| Service | Dimension | Current | Daily growth | Days to exhaustion | Exhaustion date |
|---------|-----------|---------|-------------|-------------------|-----------------|
| Host disk (/) | Disk | 84 GiB / 305 GiB (28%) | ~200-500 MiB/day | ~300-700 days | 2027 Q1-Q3 |
| Docker build cache | Disk | 21.79 GiB | ~300 MiB-1 GiB/day | ~200-700 days | depends on build frequency |
| ch-data (ClickHouse) | Volume | 278 MiB | ~34 KB/day (message log) | **~7500 years** | Negligible |
| grafana-storage | Volume | 84 MiB | ~1-5 MiB/day | ~20-80 days (small volume) | Need metric data |
| kafka-data | Volume | 11 MiB | <1 MiB/day | Very long | Negligible |
| pg15-data | Volume | 81 MiB | <1 MiB/day | Very long | Negligible |
| kyb-infra-boss (overlay) | Container | 4.55 GiB / 6h | ~18 GiB/day (extrapolated) | **~12-17 days** | 2026-06 |
| kyb-maven-cache | Volume | 6.4 GiB | ~50-200 MiB/week | Very long | Negligible |
| kyb-gradle-cache | Volume | 4.1 GiB | ~50-200 MiB/week | Very long | Negligible |

**Key finding:** Boss container overlay growth is the most urgent capacity risk. A single active boss container can grow 10+ GiB/day under heavy use. With 5 boss instances, **worst-case overlay growth could exceed available disk within 2-3 weeks** if all bosses are active simultaneously.

### 7.3 Prediction Script

```bash
#!/bin/bash
# predict-capacity.sh -- Update infra.capacity_projections table
# Runs every hour on super-boss.

CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"

# Define capacity limits per service per dimension
# Format: cluster:service:dimension:capacity_bytes
CAPACITIES=(
  "mac-orbstack:clickhouse:volume_used:32212254720"    # 30 GiB (ch-data volume)
  "mac-orbstack:grafana:volume_used:10737418240"        # 10 GiB
  "mac-orbstack:kafka:volume_used:10737418240"          # 10 GiB
  "mac-orbstack:postgresql-15:volume_used:10737418240"  # 10 GiB
  "mac-orbstack:host_disk:/:322122547200"               # 300 GiB
  "mac-orbstack:build_cache:build_cache:53687091200"    # 50 GiB
)

for entry in "${CAPACITIES[@]}"; do
  IFS=':' read -r cluster service dimension capacity <<< "$entry"

  curl -s -X POST "$CK_HOST" --data-binary "
INSERT INTO infra.capacity_projections
WITH
    recent AS (
        SELECT
            date,
            toUnixTimestamp(date) / 86400 AS day_num,
            CASE
$(for i in $(seq 0 13); do
  echo "                WHEN date = today() - $i THEN value_$i"
done)
            END AS value
        FROM ...
    )
SELECT
    '$cluster' AS cluster,
    '$service' AS service,
    '$dimension' AS dimension,
    ...
"
done
```

*(Full SQL implementation follows the same pattern as `cluster_disk_exhaustion` in the disk-growth design.)*

---

## 8. Scaling Recommendations

### 8.1 Immediate Actions (Next 48 Hours)

| Action | Rationale | Effort | Impact |
|--------|-----------|--------|--------|
| Stop and remove kyb-infra-boss-old | 8.37 GB orphan container, no operational value | 2 minutes | Recovers 8.37 GB |
| Stop kyb-infra-boss-fallback | Idle, consuming 4.57 GB; only 1 primary boss is active | 2 minutes | Recovers ~4.6 GB |
| Prune Docker build cache | 21.79 GB unmanaged build cache | `docker builder prune -a` | Recovers ~22 GB |
| Remove dangling images (7 images, ~6.4 GB) | No reference, occupying space | `docker image prune` | Recovers ~6.4 GB |
| Remove unused images older than 30 days | PeerDB 0.35.0, Alpine 3.17, Docker git image | `docker image prune -a --filter until=720h` | Recovers ~1.5 GB |
| Add memory limits to all containers | No OOM protection for 17/19 containers | 30 minutes for docker-compose or per-container config | Prevents host OOM |

**Total reclaimable disk immediately: ~43 GB** (from 84 GB used, reducing to ~41 GB, bringing host usage from 28% to ~13%).

### 8.2 Short-Term Actions (Next 1-2 Weeks)

| Action | Rationale | Effort | Impact |
|--------|-----------|--------|--------|
| Consolidate from 5 boss instances to 2 | Only 1 boss is active; others waste ~4.5 GB each | Set up boss lifecycle management | Recovers ~13-18 GB |
| Add memory limit of 4 GiB to all boss containers | Prevent runaway memory usage | Update docker run commands | Prevents OOM |
| Add memory limit of 1-2 GiB to service containers | Provide resource guarantees | Per-service config | Predictable performance |
| Set up Docker build cache TTL | Auto-prune builds older than 7 days | Docker BuildKit config | Prevents future growth |
| Schedule weekly `docker system prune` | Reclaim dangling resources automatically | Cron job | Managed cleanup |

### 8.3 Medium-Term Actions (Next 1-3 Months)

| Action | Rationale | Effort | Impact |
|--------|-----------|--------|--------|
| Migrate boss sessions to volumes | Decouple container lifecycle from data; allows clean restart | Medium | Boss containers can be recreated without losing state |
| Implement volume size quotas | Set `size` option on Docker volumes (if supported by driver) | Low | Hard limits on volume growth |
| Add dedicated CI builder host | Isolate build cache from production services | High | Prevents build cache from competing with service disk |
| Set up cross-cluster resource aggregation | Central CK already exists; add per-cluster dashboards | Low | Unified view of all 3 clusters |
| Add resource limit to kyb build | Prevent single build from exhausting host CPU/memory | Low | Stable build environment |

### 8.4 Long-Term Strategic (3-12 Months)

| Action | Rationale |
|--------|-----------|
| Set up cluster-level quotas | Each cluster gets a resource budget; prevent one cluster from dominating |
| Implement auto-scaling for boss containers | When CPU > 80% for 5 min, spawn a new boss; when CPU < 10% for 30 min, retire |
| Add Office (nuc8) and Aliyun (sim) capacity monitoring | Currently only Mac/Orbstack is monitored; other clusters have different constraints |
| Consider k8s for boss orchestration | Docker-only becomes unwieldy past 3 clusters |

### 8.5 Per-Service Scaling Rules

Thresholds that trigger scaling recommendations:

| Service | Dimension | Warning threshold | Critical threshold | Scaling action |
|---------|-----------|-------------------|-------------------|----------------|
| Boss containers | Memory | > 3 GiB RSS | > 4 GiB RSS | Add memory limit; investigate leak |
| Boss containers | CPU | > 80% (10m avg) | > 95% (5m avg) | Add another boss; distribute load |
| Boss containers | Overlay | > 10 GiB | > 20 GiB | Restart container; migrate state to volume |
| ClickHouse | Volume | > 80% of volume | > 90% of volume | Add volume storage; extend TTL |
| Grafana | Volume | > 80% of volume | > 90% of volume | Increase volume size; clean old alerts |
| Kafka | Volume | > 80% of volume | > 90% of volume | Reduce retention; add storage |
| PostgreSQL | Volume | > 80% of volume | > 90% of volume | Vacuum; archive old data; add storage |
| Host disk (/) | Disk | < 30 GiB free | < 10 GiB free | Run cleanup; inform admin |
| Host memory | RAM | < 2 GiB available | < 512 MiB available | Stop non-essential containers; add swap |
| Docker build cache | Cache | > 30 GiB | > 50 GiB | `docker builder prune` |
| Container without memory limit | Memory | all containers | N/A | Add `--memory` limit immediately |
| Container without restart policy | Restart | all containers | N/A | Add `--restart unless-stopped` |

### 8.6 Cleanup Candidate Identification

Query to find stale resources:

```sql
-- Containers with zero CPU for >6 hours (idle candidates)
SELECT
    container_name,
    service,
    max(cpu_usage_pct) AS max_cpu,
    min(timestamp) AS first_seen,
    argMax(container_size_bytes, timestamp) AS current_size
FROM infra.container_metrics
WHERE timestamp > now() - INTERVAL 1 DAY
GROUP BY container_name, service
HAVING max_cpu < 5.0
ORDER BY current_size DESC;

-- Stale containers (running >7 days with no recent CPU spikes)
SELECT
    container_name,
    service,
    dateDiff('day', first_seen, now()) AS age_days,
    current_size
FROM (
    SELECT
        container_name,
        service,
        min(timestamp) AS first_seen,
        max(cpu_usage_pct) AS max_cpu_lifetime,
        argMax(container_size_bytes, timestamp) AS current_size
    FROM infra.container_metrics
    GROUP BY container_name, service
)
WHERE age_days > 7 AND max_cpu_lifetime < 10
ORDER BY current_size DESC;
```

---

## 9. Grafana Dashboard

### Overview Dashboard: "Capacity Planning"

#### Panel 1: Host Resource Overview (Stat + Gauge)

- **Host Disk**: gauge showing used_pct, with thresholds (green < 70%, yellow 70-85%, red > 85%)
- **Host Memory**: gauge showing mem_used_pct
- **Host CPU**: stat showing load_1m / cpu_count

#### Panel 2: Top-N Container Memory (Bar Chart)

- Query: `SELECT service, mem_rss_bytes FROM infra.container_metrics WHERE timestamp = (SELECT max(timestamp) FROM infra.container_metrics) ORDER BY mem_rss_bytes DESC LIMIT 10`
- Display: Horizontal bar chart highlighting the top memory consumers
- Purpose: Quick identification of memory hogs

#### Panel 3: Top-N Container CPU (Bar Chart)

- Query: `SELECT service, cpu_usage_pct FROM infra.container_metrics ... ORDER BY cpu_usage_pct DESC LIMIT 10`
- Display: Horizontal bar chart
- Purpose: Identify CPU-intensive containers

#### Panel 4: Disk Growth Trajectory (Time Series)

- Query: `SELECT timestamp, service, container_size_eod FROM infra.capacity_daily_mv WHERE $__timeFilter ORDER BY timestamp`
- Display: Multi-line, one per service
- Overlay: Dashed projection line for fast-growing services

#### Panel 5: Exhaustion Countdown (Table)

- Query:
  ```sql
  SELECT
    cluster, service, dimension,
    formatReadableSize(current_value) AS current,
    formatReadableSize(daily_growth) AS daily_growth,
    round(daily_growth_pct, 4) AS daily_pct,
    round(days_until_full, 1) AS days_left,
    exhaustion_date,
    confidence,
    CASE WHEN critical THEN 'CRITICAL' WHEN warning THEN 'WARNING' ELSE 'OK' END AS status
  FROM infra.capacity_projections
  ORDER BY days_until_full ASC NULLS LAST
  ```
- Display: Table with conditional formatting (red for critical, yellow for warning)
- Purpose: At-a-glance view of what will fill up next

#### Panel 6: Volume Growth (Time Series)

- Query: `SELECT timestamp, volume_name, used_bytes FROM infra.volume_metrics WHERE $__timeFilter ORDER BY timestamp`
- Display: Multi-line chart, one line per volume
- Purpose: Track named volume sizes over time

#### Panel 7: Container Without Memory Limit (Table)

- Query:
  ```sql
  SELECT container_name, service, mem_rss_bytes, 'UNLIMITED' AS mem_limit
  FROM infra.container_metrics
  WHERE mem_limit_bytes = 0 OR mem_limit_bytes >= 17179869184
    AND timestamp = (SELECT max(timestamp) FROM infra.container_metrics)
  ORDER BY mem_rss_bytes DESC
  ```
- Display: Table showing all containers without meaningful memory limits
- Purpose: Track remediation progress for unlimited containers

#### Panel 8: Daily Growth Rate (Bar Chart)

- Query: `SELECT date, service, blk_write_daily FROM infra.capacity_daily_mv WHERE $__timeFilter`
- Display: Stacked bar chart per service per day
- Purpose: Spot unusual growth days

#### Panel 9: Stale Container Candidates (Table)

- Query from section 8.6: containers with zero CPU for >6 hours
- Display: Table with container name, size, last active timestamp

#### Panel 10: Build Cache Growth (Time Series)

- Query: `SELECT timestamp, build_cache_bytes FROM infra.host_metrics WHERE $__timeFilter`
- Display: Area chart showing build cache growth over time
- Overlay: Horizontal line at 30 GiB (warning) and 50 GiB (critical)

---

## 10. Alerting

### 10.1 Alert Rules

| Rule | Condition | Severity | Channel | Cooldown |
|------|-----------|----------|---------|----------|
| Host disk critical | avail_bytes < critical_bytes OR used_pct > 95 | P0 | Feishu urgent | 1 hour |
| Host disk warning | avail_bytes < warning_bytes OR days_until_full < warning_days | P1 | Feishu info | 6 hours |
| Container OOM risk | mem_rss_bytes > 90% of mem_limit (or > 90% of host memory if unlimited) | P1 | Feishu urgent | 5 minutes |
| Container CPU saturation | cpu_usage_pct > 90% for > 5 minutes | P2 | Feishu info | 10 minutes |
| Volume growth acceleration | daily_growth > 2x previous 7-day average | P2 | Feishu info | 1 hour |
| Build cache too large | build_cache_bytes > 30 GiB | P2 | Feishu info | 6 hours |
| Stale container detected | Zero CPU for > 24 hours | P3 | Feishu info | 24 hours |
| Exhaustion < 7 days | days_until_full < 7 | P0 | Feishu urgent | 1 hour |
| Exhaustion < 30 days | days_until_full < 30 | P1 | Feishu info | 6 hours |

### 10.2 Alert Message Format

```
[DISK CRITICAL] Host disk exhaustion imminent on mac-orbstack
  - Used: 280 GiB / 305 GiB (92%)
  - Available: 25 GiB
  - Daily growth: ~500 MiB/day
  - Predicted exhaustion: 2026-06-15 (in 23 days)
  - Top contributors: boss overlays (45 GiB), build cache (22 GiB), images (34 GiB)
  - Recommendation: Run `docker system prune -a`, remove idle boss containers

[OOM RISK] Container memory pressure on kyb-infra-boss
  - RSS: 3.8 GiB / unlimited
  - Growth rate: ~200 MiB/hour
  - Host available memory: 1.2 GiB
  - Recommendation: Add `--memory 4g` limit; investigate memory leak
```

### 10.3 Integration with Patrol

Add to the 5-minute patrol script:

```bash
# Capacity alert check
CAPACITY_ALERTS=$(curl -s "http://100.104.244.99:8123?query=
SELECT cluster, service, dimension, days_until_full, exhaustion_date
FROM infra.capacity_projections
WHERE critical = 1
ORDER BY days_until_full ASC
FORMAT TSVWithNames" 2>/dev/null)

if [ -n "$CAPACITY_ALERTS" ] && [ "$(echo "$CAPACITY_ALERTS" | wc -l)" -gt 1 ]; then
  kyb notify urgent "Capacity critical: $(echo "$CAPACITY_ALERTS" | tail -1)"
fi
```

### 10.4 Auto-Remediation

For P0 alerts, trigger auto-remediation:

| Condition | Auto-action | Safety |
|-----------|------------|--------|
| Host disk < 5 GiB free | Prune Docker build cache `docker builder prune -af` | Non-destructive |
| Host disk < 2 GiB free | Prune all unused images `docker image prune -af` | Non-destructive (containers unaffected) |
| Host memory < 256 MiB available | Stop non-essential containers (registry-cache, ubuntu-test, etc.) | Requires manual restart |
| Container overlay > 20 GiB | Restart container with `--rm` volume migration | Data loss risk -- manual only |

Auto-remediation is opt-in per cluster. Mac/Orbstack may enable auto-prune only.

---

## 11. Cluster-Specific Profiles

### 11.1 Mac/Orbstack (Super-Boss)

| Resource | Value | Constraints | Critical at |
|----------|-------|------------|-------------|
| Disk | 305 GiB (84 GiB used) | Mac SSD (shared with host OS) | < 30 GiB free |
| RAM | 15 GiB (7.7 GiB used) | Mac shared memory | < 2 GiB available |
| CPU | 10 cores | Mac shared | > 80% sustained |
| Containers | 19 running | Unlimited | No limit, but quality degrades |

**Growth pattern**: Fastest-growing cluster due to active development. The boss container at 365% CPU drives the majority of disk and memory growth.

**Scaling bottleneck**: CPU on the primary boss, disk from unmanaged build cache + container overlays.

**Recommendation**: 
- Prune immediately (~43 GB reclaimable)
- Add memory limits to prevent OOM
- Schedule weekly Docker system prune
- Move to 2 boss instances (primary + hot standby)

### 11.2 Aliyun (sim, Cluster Boss)

| Resource | Value | Constraints | Critical at |
|----------|-------|------------|-------------|
| Disk | 40 GiB | ESSD cloud disk (expensive to resize) | < 5 GiB free |
| RAM | Unknown (est. 2-4 GiB) | ECS instance | < 512 MiB available |
| CPU | Unknown (est. 2-4 cores) | ECS instance | > 80% sustained |

**Growth pattern**: Minimal data currently. No active cc-connect or heavy services.

**Scaling bottleneck**: Disk is the primary constraint at 40 GiB. Every GB matters.

**Recommendation**:
- Implement disk monitoring immediately (from disk-growth.md)
- Set aggressive thresholds: warning at < 5 GiB, critical at < 2 GiB
- Plan for 80 GiB disk upgrade when growth approaches 80%
- Do not deploy additional services without disk expansion

### 11.3 Office (nuc8, Cluster Boss)

| Resource | Value | Constraints | Critical at |
|----------|-------|------------|-------------|
| Disk | ~256 GiB (est.) | NUC SSD | < 30 GiB free |
| RAM | Unknown (est. 8-16 GiB) | NUC | < 2 GiB available |
| CPU | Unknown (est. 4-8 cores) | NUC | > 80% sustained |

**Growth pattern**: Unknown -- no monitoring deployed yet. Likely minimal.

**Scaling bottleneck**: Unknown.

**Recommendation**:
- Deploy metrics collectors first
- Establish baseline before setting thresholds

### 11.4 Threshold Matrix

| Alert | Mac/Orbstack | Aliyun | Office |
|-------|-------------|--------|--------|
| Warning: avail disk | < 30 GiB | < 5 GiB | < 20 GiB |
| Critical: avail disk | < 10 GiB | < 2 GiB | < 5 GiB |
| Warning: days to full | < 30 days | < 14 days | < 30 days |
| Critical: days to full | < 7 days | < 3 days | < 7 days |
| Warning: mem available | < 2 GiB | < 512 MiB | < 1 GiB |
| Critical: mem available | < 512 MiB | < 128 MiB | < 256 MiB |
| Warning: build cache | > 30 GiB | > 10 GiB | > 20 GiB |
| Critical: build cache | > 50 GiB | > 15 GiB | > 30 GiB |

---

## 12. Rollout Plan

### Phase 1: Baseline Collection (Day 1)

1. Create ClickHouse database `infra` and all tables (sections 5.1-5.5).
2. Deploy `collect-container-metrics.sh` on super-boss (Mac/Orbstack).
3. Deploy `collect-host-metrics.sh` on super-boss.
4. Deploy `collect-volume-metrics.sh` on super-boss.
5. Verify data ingestion after 5 minutes.

### Phase 2: Prediction Engine (Day 1-2)

1. Deploy `predict-capacity.sh` on super-boss (runs hourly).
2. Verify projections against manual calculations.
3. Adjust capacity limits for each service.

### Phase 3: Visualization (Day 2-3)

1. Build Grafana "Capacity Planning" dashboard (section 9).
2. Share with team for feedback.
3. Iterate on panel layout and queries.

### Phase 4: Alerting (Day 3-4)

1. Add capacity checks to patrol script.
2. Configure cc-connect cron for Feishu alerts.
3. Set initial thresholds, observe for 24 hours.

### Phase 5: Cleanup (Day 4-5)

1. Remove kyb-infra-boss-old (8.37 GB reclaim).
2. Prune Docker build cache (21.79 GB reclaim).
3. Remove dangling images.
4. Consolidate boss instances from 5 to 2.

### Phase 6: Multi-Cluster Rollout (Week 2)

1. Deploy collectors to Aliyun (sim).
2. Deploy collectors to Office (nuc8).
3. Validate end-to-end from central CK on Mac/Orbstack.
4. Set cluster-specific thresholds.

### Phase 7: Continuous Tuning (Week 2-4)

1. Review alert frequency; tune thresholds if noise is too high.
2. Add auto-remediation for P0 disk alerts (optional).
3. Document capacity planning runbook.
4. Schedule monthly capacity review meeting.

---

## Appendix A: Components Without Resource Limits

As of 2026-05-23, the following containers have **no memory limit, no CPU limit, and no restart policy**:

| Container | Memory (RSS) | Risk | Recommended limit |
|-----------|-------------|------|-------------------|
| kyb-infra-boss | 1.09 GiB | HIGH (365% CPU) | 4 GiB |
| kyb-infra-clickhouse | 728 MiB | MEDIUM | 2 GiB |
| kyb-infra-kafka | 475 MiB | MEDIUM | 2 GiB |
| kyb-infra-boss-old | 439 MiB | LOW (idle) | Clean up instead |
| kyb-infra-boss-fallback | 349 MiB | LOW (idle) | 2 GiB or clean up |
| kyb-infra-boss3 | 327 MiB | LOW (idle) | 2 GiB or clean up |
| kyb-infra-cc-connect | 276 MiB | MEDIUM | 1 GiB |
| kyb-infra-grafana | 264 MiB | LOW | 1 GiB |
| kyb-infra-sing-box | 34 MiB | LOW | 256 MiB |
| kyb-infra-postgresql-15 | 30 MiB | LOW | 512 MiB |
| kyb-infra-postgresql-16 | 10 MiB | LOW | 512 MiB |
| kyb-infra-postgresql-17 | 11 MiB | LOW | 512 MiB |
| kyb-infra-postgresql-14 | 8 MiB | LOW | 512 MiB |
| kyb-registry-cache | 8 MiB | LOW | 256 MiB |
| kyb-infra-redis | 7 MiB | LOW | 256 MiB |
| kyb-infra-boss2 | 50 MiB | LOW (has 4 GiB limit already) | 4 GiB (OK) |

**Total manageable with limits: ~16 GiB** (fit within 15 GiB host memory, but tight with overhead).

## Appendix B: Cleanup Priority Matrix

| Resource | Size | Cleanup ease | Impact | Priority |
|----------|------|-------------|--------|----------|
| Docker build cache | 21.79 GiB | Easy (`docker builder prune -a`) | Non-disruptive | P0 |
| kyb-infra-boss-old | 8.37 GiB | Easy (`docker rm`) | Non-disruptive (already stopped) | P0 |
| Dangling images | ~6.4 GiB | Easy (`docker image prune`) | Non-disruptive | P0 |
| kyb-infra-boss-fallback | 4.57 GiB | Easy (`docker rm`) | Low risk (primary is active) | P1 |
| Unused images (30d+) | ~1.5 GiB | Easy (`docker image prune -a --filter until=720h`) | Non-disruptive (no container uses them) | P1 |
| Alpine 3.17/3.18 images | ~25 MiB | Easy (`docker image rm`) | Non-disruptive | P2 |
| PeerDB 0.35.0 images | ~365 MiB | Easy (`docker image rm`) | Disruptive if PeerDB is restarted | P2 |

**Total P0+P1 immediate reclaim: ~42.5 GB**

## Appendix C: Metric Collection Cost

| Metric type | Samples/day | Per-sample size (CK compressed) | Daily storage | 180-day storage |
|-------------|-------------|-------------------------------|--------------|-----------------|
| Container (19 containers x 1440 samples) | 27,360 | ~200 bytes | ~5.5 MB | ~1 GB |
| Host (1 host x 1440 samples) | 1,440 | ~300 bytes | ~432 KB | ~78 MB |
| Volume (26 volumes x 24 samples) | 624 | ~150 bytes | ~94 KB | ~17 MB |
| Projections (hourly) | 24 | ~500 bytes | ~12 KB | ~2 MB |

**Total estimated storage for 180 days: ~1.1 GB** -- negligible for ClickHouse.

## Appendix D: Future Work

1. **Grafana alert rules** -- native Grafana alerts on capacity_projections table
2. **Anomaly detection** -- detect sudden growth spikes (e.g., runaway log, session leak)
3. **Cost tracking** -- if using cloud disk (sim/Aliyun), track cost per GB per month
4. **Capacity budgets** -- assign resource budgets per service, alert on overspend
5. **Auto-scaling** -- when boss CPU > 80%, auto-create new boss instance; when CPU < 10% for 1h, retire
6. **Reserved capacity** -- reserve X% of host resources for critical services (cc-connect, ClickHouse)
7. **Office/nuc8 baseline** -- deploy collectors and establish 14-day baseline

---

> **Summary:** Per-service resource tracking (CPU, memory, volume, overlay, network, build cache) collected every 60-300 seconds into ClickHouse, projected against capacity limits using linear regression, and alerted at cluster-specific thresholds. Immediate action: recover ~43 GiB of disk by pruning build cache and removing stale containers. Followed by: adding memory limits to all containers (currently 17/19 unlimited), consolidating 5 boss instances to 2, and deploying collectors to Aliyun and Office clusters.

> /人◕ ‿‿ ◕人＼
