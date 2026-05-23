---
decision: 稍后做
---

# Design: Docker Image Pull Duration Monitoring

**Design doc**: `docs/infra/reviews/image-pull.md`
**Reviewer**: kyb
**Date**: 2026-05-23
**Scope**: Capture image pull timing, cache hit ratio, per-registry performance across all clusters.

---

## Summary

Image pull latency is a significant factor in container startup time, especially on bandwidth-constrained machines (sim server with 小水管) and during burst provisioning (multiple sandbox creations). The existing `kyb-registry-cache` pull-through proxy already reduces redundant downloads, but there is currently **zero observability** into:

- How long each pull takes
- Whether the pull was served from the local cache or fetched from the upstream registry
- Which images/registries are the slowest
- Whether the registry cache is actually helping (cache hit ratio)
- Pull success/failure rate per registry

This design fills that gap by instrumenting the `docker pull` path at three collection points and forwarding metrics to ClickHouse for analysis and alerting.

---

## Architecture

### Data Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│  Collection Sources                                                   │
│                                                                       │
│  1. Registry Cache Access Logs                                        │
│     kyb-infra-registry (registry:2)                                   │
│     stdout (HTTP access log) → parsed by Vector                       │
│     → cache hit/miss per blob request                                 │
│                                                                       │
│  2. docker-pull-wrapper                                               │
│     Wraps every `docker pull` called from kyb scripts                 │
│     → start/end timestamps, total bytes, layers pulled                │
│                                                                       │
│  3. docker-event-watcher extension                                    │
│     Captures image:pull Docker events                                 │
│     → pull trigger detection, image name extraction                   │
│                                                                       │
└──────────────────────────┬───────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Vector / HTTP POST                                                  │
│  → ClickHouse (host.orb.internal:8123)                                │
└──────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  ClickHouse Tables                                                    │
│  infra.image_pulls        ← per-pull event record                     │
│  infra.image_pull_layers  ← per-layer detail (cache hit/miss)         │
│  infra.registry_requests  ← raw registry cache access logs            │
│  infra.image_pull_hourly  ← materialized view for aggregated metrics  │
└──────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Grafana Dashboards                                                   │
│  - Pull Duration Overview (P50/P90/P99 per image/registry)            │
│  - Cache Hit Ratio (time series)                                      │
│  - Slow Pull Alerts (threshold + anomaly)                             │
│  - Registry Cache Health (request rate, error rate)                   │
└──────────────────────────────────────────────────────────────────────┘
```

### Collection Points

| Source | What It Captures | Deployment |
|--------|-----------------|------------|
| **Registry cache access logs** | Per-blob request: image, blob digest, status (200=cache hit, 404=miss or unknown blob), duration, bytes | Vector container on each boss that runs kyb-infra-registry |
| **docker-pull-wrapper** | Per-pull: image:tag, start_time, end_time, total_bytes, layers_pulled, layers_cached, exit_code | Installed as `~/.kyb/bin/docker-pull` on all boss containers; wraps real `docker pull` |
| **docker-event-watcher extension** | Image pull trigger events (discovery: which images are being pulled) | Extension to existing `docker-event-watcher.sh` on all bosses |

---

## 2. Collection Approach

### 2.1 Registry Cache Access Logs (primary source for cache hit ratio)

The `kyb-infra-registry` (registry:2) container emits HTTP access logs to stdout. Each request to the registry produces a log line like:

```
172.17.0.1 - - [23/May/2026:10:30:15 +0000] "GET /v2/library/postgres/blobs/sha256:a1b2c3d4 HTTP/1.1" 200 12345678 "" "docker/27.0 (linux)"
```

The key signals in these logs:
- **Status 200**: blob was served from cache (or fetched from upstream on first request)
- **Status 404**: blob unknown to cache — usually means it needs to be fetched from upstream
- **Status 503**: upstream registry unavailable
- **Duration**: the registry's built-in logging does not include response time by default, but `$upstream_response_time` can be added via registry config

**Registry access log format** (registry:2 default):

```
$remote_addr - - [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" $request_time
```

The `$request_time` variable is available in the registry's logging configuration. To enable it, set the `REGISTRY_HTTP_LOG_FIELDS` environment variable on the registry container.

**Vector collection**:

```toml
[sources.registry_logs]
type = "docker_logs"
include_containers = ["kyb-infra-registry"]

[transforms.parse_registry_log]
type = "remap"
inputs = ["registry_logs"]
source = '''
  # Parse registry access log line
  # Format: $remote_addr - - [$time_local] "$method $path $protocol" $status $bytes "$referer" "$agent" $request_time
  parsed = parse_regex!(.message, r'^(?P<remote_addr>\S+) - - \[(?P<time_local>[^\]]+)\] "(?P<method>\S+) (?P<path>\S+) \S+" (?P<status>\d+) (?P<bytes>\d+) "[^"]*" "[^"]*" (?P<request_time>\S+)$')
  
  .remote_addr = parsed.remote_addr
  .event_time = parse_timestamp!(parsed.time_local, format: "%d/%b/%Y:%H:%M:%S %z")
  .method = parsed.method
  .path = parsed.path
  .status = to_int!(parsed.status)
  .bytes_sent = to_int!(parsed.bytes)
  .request_time_sec = to_float!(parsed.request_time)
  
  # Extract image and blob info from path
  # Path patterns:
  #   /v2/<image>/blobs/<digest>          - blob download
  #   /v2/<image>/manifests/<tag>         - manifest fetch
  #   /v2/_catalog                        - catalog listing
  parts = split(.path, "/")
  
  if length(parts) >= 4 && parts[1] == "v2" {
    .image_path = join(parts[2:length(parts)-2], "/")
    
    if parts[length(parts)-1] == "blobs" {
      .request_type = "blob"
      .blob_digest = parts[length(parts)]
    } else if parts[length(parts)-1] == "manifests" {
      .request_type = "manifest"
      .tag_or_digest = parts[length(parts)]
    } else {
      .request_type = "other"
    }
    
    # Determine if this was a cache hit:
    # For registry:2 as pull-through proxy:
    #   - 200 on first pull = miss (fetched from upstream, now cached)
    #   - 200 on subsequent = hit (served from local cache)
    # We track per-blob digest to detect first-seen vs cached
    .cache_hit = (parsed.status == "200" && .request_type == "blob") ? true : false
  }
'''

[sinks.registry_requests]
type = "clickhouse"
inputs = ["parse_registry_log"]
endpoint = "http://host.orb.internal:8123"
database = "infra"
table = "registry_requests"
compression = "lz4"

[sinks.registry_requests.batch]
max_events = 200
timeout_secs = 2
```

### 2.2 docker-pull-wrapper (primary source for pull timing)

A wrapper script that intercepts `docker pull` and measures start-to-finish time, bytes transferred, and layer cache statistics. Installed as `~/.kyb/bin/docker-pull` on all boss/sandbox containers.

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/docker-pull
# Wrapper around `docker pull` that records timing and layer stats.
# Usage: docker-pull <image:tag>
# Metrics are POSTed to ClickHouse after successful pull.

set -euo pipefail

IMAGE="${1:?usage: docker-pull <image:tag>}"
PULL_START=$(date +%s%N)  # nanoseconds

# Run the real pull, capturing output for layer analysis
PULL_OUTPUT=$(docker pull "$IMAGE" 2>&1)
PULL_EXIT=$?
PULL_END=$(date +%s%N)
PULL_DURATION_MS=$(( (PULL_END - PULL_START) / 1000000 ))

# Parse docker pull output for layer stats
# Typical output:
#   Pulling from library/postgres (digest)
#   Digest: sha256:...
#   Status: Downloaded newer image for postgres:16-alpine
#   or
#   Status: Image is up to date for postgres:16-alpine
#
# If verbose: each layer shows "Already exists" (cached) or "Pull complete" (downloaded)

# Count layers
LAYERS_TOTAL=$(echo "$PULL_OUTPUT" | grep -cE '(Already exists|Pull complete|Waiting|Downloading|Verifying)' || true)
LAYERS_CACHED=$(echo "$PULL_OUTPUT" | grep -c 'Already exists' || true)
LAYERS_PULLED=$(echo "$PULL_OUTPUT" | grep -c 'Pull complete' || true)
BYTES_TRANSFERRED=$(echo "$PULL_OUTPUT" | grep -oP '[\d.]+\s?(kB|MB|GB)' | tail -1 || echo "0")

# Detect cache status
if echo "$PULL_OUTPUT" | grep -q "Image is up to date"; then
  CACHE_STATUS="up_to_date"
elif echo "$PULL_OUTPUT" | grep -q "Downloaded newer image"; then
  CACHE_STATUS="fresh_pull"
elif echo "$PULL_OUTPUT" | grep -q "Already exists"; then
  CACHE_STATUS="partial_cache"
else
  CACHE_STATUS="unknown"
fi

# Extract registry from image name
REGISTRY="docker.io"
if [[ "$IMAGE" == */*.*/* ]]; then
  REGISTRY=$(echo "$IMAGE" | cut -d/ -f1)
fi

# Post to ClickHouse (fire-and-forget)
JSON_PAYLOAD=$(cat <<JSON
{
  "event_time": $(date +%s),
  "image": "${IMAGE%%:*}",
  "tag": "${IMAGE#*:}",
  "registry": "$REGISTRY",
  "pull_duration_ms": $PULL_DURATION_MS,
  "layers_total": ${LAYERS_TOTAL:-0},
  "layers_cached": ${LAYERS_CACHED:-0},
  "layers_pulled": ${LAYERS_PULLED:-0},
  "bytes_transferred": 0,
  "cache_status": "$CACHE_STATUS",
  "exit_code": $PULL_EXIT,
  "boss_id": "$(hostname)",
  "cluster": "${CLUSTER_NAME:-unknown}"
}
JSON
)

curl -s -X POST "http://host.orb.internal:8123?query=INSERT+INTO+infra.image_pulls+FORMAT+JSONEachRow" \
  -d "$JSON_PAYLOAD" \
  --max-time 5 --noproxy '*' 2>/dev/null || true

# Forward exit code from docker pull
exit $PULL_EXIT
```

**Installation**: Replace direct `docker pull` calls with the wrapper. For kyb-managed containers, set an alias in `.bashrc`:

```bash
# ~/.bashrc or /home/dev/.bashrc
alias docker-pull='~/.kyb/bin/docker-pull'
```

But more reliably, the kyb CLI itself (`bin/kyb`, `lib/kyb/`) should call the wrapper. For external images pulled by `docker run --pull=always`, the wrapper does not apply — those are covered by the registry cache access logs.

### 2.3 docker-event-watcher extension (discovery)

Extend the existing `docker-event-watcher.sh` to also capture `image:pull` Docker events. These events fire when Docker Engine initiates an image pull but do **not** include timing information — they serve as a discovery mechanism to know which images are being pulled.

```bash
# Add to the existing docker-events filter list:
docker events \
  --filter 'type=container' \
  --filter 'event=create' \
  --filter 'event=start' \
  --filter 'event=die' \
  --filter 'event=destroy' \
  --filter 'event=pull' \          # <-- ADD THIS
  --filter 'event=import' \        # <-- ADD THIS (when image is imported)
  ...
```

Docker `image:pull` event format:
```json
{
  "Type": "image",
  "Action": "pull",
  "Actor": {
    "ID": "postgres:16-alpine",
    "Attributes": {
      "name": "postgres:16-alpine"
    }
  },
  "time": 1745371815,
  "timeNano": 1745371815123456789
}
```

The event watcher records the pull trigger in a separate CK table or adds to the existing `infra.docker_events` with `event_type: 'image:pull'`. This allows correlation with the detailed pull metrics from the other sources.

---

## 3. ClickHouse Schemas

### 3.1 `infra.image_pulls` — per-pull event record

Written once per `docker pull` invocation by the wrapper script.

```sql
CREATE TABLE infra.image_pulls (
    event_time          DateTime                COMMENT 'Pull completion time',
    image               LowCardinality(String)  COMMENT 'Image name without tag (e.g., library/postgres)',
    tag                 LowCardinality(String)  COMMENT 'Image tag (e.g., 16-alpine)',
    registry            LowCardinality(String)  COMMENT 'Registry host (docker.io, ghcr.io, 10.0.0.1:5000)',
    pull_duration_ms    UInt32                  COMMENT 'Total pull time in milliseconds',
    layers_total        UInt16                  COMMENT 'Total layers in the image',
    layers_cached       UInt16                  COMMENT 'Layers served from local cache (Already exists)',
    layers_pulled       UInt16                  COMMENT 'Layers downloaded fresh (Pull complete)',
    bytes_transferred   UInt64                  COMMENT 'Total bytes downloaded on the wire',
    cache_status        LowCardinality(String)  COMMENT 'up_to_date | fresh_pull | partial_cache | unknown',
    exit_code           UInt8                   COMMENT '0 = success, non-zero = failure',
    boss_id             LowCardinality(String)  COMMENT 'Hostname of the boss container',
    cluster             LowCardinality(String)  COMMENT 'mac-orbstack | aliyun | office',
    error_message       String DEFAULT ''       COMMENT 'Error message if pull failed',

    -- Derived
    cache_hit_ratio     Float32                 COMMENT 'layers_cached / layers_total (0..1)',
    pull_speed_bps      Float64                 COMMENT 'bytes_transferred / (pull_duration_ms/1000) in bytes/sec',
    image_full          String DEFAULT ''       COMMENT 'image:tag for convenience',

    -- Ingestion metadata
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (event_time, registry, image)
TTL event_time + INTERVAL 90 DAY;
```

### 3.2 `infra.image_pull_layers` — per-layer detail (optional, for deep analysis)

For verbose pull output, track each layer individually. This is optional but enables precise cache hit analysis.

```sql
CREATE TABLE infra.image_pull_layers (
    event_time      DateTime                COMMENT 'Pull completion time',
    image           LowCardinality(String)  COMMENT 'Image name',
    tag             LowCardinality(String)  COMMENT 'Image tag',
    layer_digest    String                  COMMENT 'Layer sha256 digest',
    layer_index     UInt16                  COMMENT 'Layer position (0 = bottom layer)',
    layer_size      UInt64                  COMMENT 'Layer size in bytes',
    was_cached      UInt8                   COMMENT '1 = Already exists (cache hit), 0 = Pull complete (cache miss)',
    pull_duration_ms UInt32                 COMMENT 'Time to pull this specific layer',
    boss_id         LowCardinality(String)
) ENGINE = MergeTree
ORDER BY (event_time, image)
TTL event_time + INTERVAL 30 DAY;
```

### 3.3 `infra.registry_requests` — raw registry access logs

Written by Vector from the registry container stdout.

```sql
CREATE TABLE infra.registry_requests (
    event_time      DateTime                COMMENT 'Request timestamp (from registry log)',
    remote_addr     String                  COMMENT 'Client IP (container or host)',
    method          LowCardinality(String)  COMMENT 'HTTP method: GET / HEAD',
    path            String                  COMMENT 'Request path (/v2/...)',
    status          UInt16                  COMMENT 'HTTP status: 200 (hit), 404 (miss), 503 (upstream down)',
    bytes_sent      UInt64                  COMMENT 'Response body bytes',
    request_time_sec Float32                COMMENT 'Request processing time in seconds (from registry)',
    image_path      String                  COMMENT 'Extracted image path from URL',
    request_type    LowCardinality(String)  COMMENT 'blob | manifest | catalog | other',
    blob_digest     String DEFAULT ''       COMMENT 'Blob digest if request_type=blob',
    tag_or_digest   String DEFAULT ''       COMMENT 'Tag or digest if request_type=manifest',
    cache_hit       UInt8                   COMMENT '1 = blob served from cache, 0 = miss (first pull)',
    boss_id         LowCardinality(String)  COMMENT 'Hostname of the boss running the registry',
    cluster         LowCardinality(String)  COMMENT 'Cluster where the registry is deployed',

    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (event_time, image_path, status)
TTL event_time + INTERVAL 14 DAY;

-- Shorter TTL (14 days) because this is raw, high-volume data.
-- Aggregated views provide longer retention.
```

### 3.4 `infra.image_pull_hourly` — materialized view for aggregated metrics

```sql
CREATE MATERIALIZED VIEW infra.image_pull_hourly
ENGINE = SummingMergeTree
ORDER BY (toStartOfHour(event_time), registry, image)
POPULATE AS
SELECT
    toStartOfHour(event_time) AS hour,
    registry,
    image,
    count()                     AS pull_count,
    sum(pull_duration_ms)       AS total_duration_ms,
    avg(pull_duration_ms)       AS avg_duration_ms,
    min(pull_duration_ms)       AS min_duration_ms,
    max(pull_duration_ms)       AS max_duration_ms,
    quantileMerge(0.50)(toFloat64(pull_duration_ms)) AS p50_duration_ms,
    quantileMerge(0.90)(toFloat64(pull_duration_ms)) AS p90_duration_ms,
    quantileMerge(0.99)(toFloat64(pull_duration_ms)) AS p99_duration_ms,
    sum(layers_total)           AS total_layers,
    sum(layers_cached)          AS total_layers_cached,
    sum(layers_pulled)          AS total_layers_pulled,
    sum(bytes_transferred)      AS total_bytes,
    countIf(exit_code = 0)      AS success_count,
    countIf(exit_code != 0)     AS fail_count,
    avg(cache_hit_ratio)        AS avg_cache_hit_ratio
FROM infra.image_pulls
GROUP BY hour, registry, image;
```

### 3.5 `infra.registry_cache_stats` — registry-level cache metrics (daily)

```sql
CREATE MATERIALIZED VIEW infra.registry_cache_stats
ENGINE = SummingMergeTree
ORDER BY (toDate(event_time), image_path)
POPULATE AS
SELECT
    toDate(event_time) AS day,
    image_path,
    countIf(request_type = 'blob')                  AS total_blob_requests,
    countIf(request_type = 'blob' AND status = 200) AS blob_hits,
    countIf(request_type = 'blob' AND status = 404) AS blob_misses,
    countIf(request_type = 'blob' AND status = 503) AS upstream_errors,
    sumIf(bytes_sent, request_type = 'blob')        AS total_bytes_served,
    avgIf(request_time_sec, request_type = 'blob')  AS avg_request_time_sec,
    quantileMerge(0.95)(toFloat64(request_time_sec)) AS p95_request_time_sec,
    cluster,
    boss_id
FROM infra.registry_requests
GROUP BY day, image_path, cluster, boss_id;
```

---

## 4. Metrics & Dimensions

### 4.1 Pull Timing

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `infra.image_pull.duration_ms` | histogram | wrapper | Total pull time |
| `infra.image_pull.bytes_transferred` | histogram | wrapper | Bytes on wire |
| `infra.image_pull.p50_duration` | gauge | hourly MV | Median pull time per image |
| `infra.image_pull.p90_duration` | gauge | hourly MV | P90 pull time per image |
| `infra.image_pull.p99_duration` | gauge | hourly MV | P99 pull time per image |
| `infra.image_pull.speed_bps` | histogram | wrapper | Pull throughput |
| `infra.registry.request_time_sec` | histogram | access logs | Registry response time |

### 4.2 Cache Efficiency

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `infra.image_pull.layers_cached` | counter | wrapper | Layers served from cache |
| `infra.image_pull.layers_pulled` | counter | wrapper | Layers downloaded fresh |
| `infra.image_pull.cache_hit_ratio` | gauge | wrapper | layers_cached / layers_total |
| `infra.registry.blob_hit_ratio` | gauge | access logs | 200 / (200 + 404) for blob requests |
| `infra.registry.upstream_errors` | counter | access logs | 503 responses from registry |

### 4.3 Failure Detection

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `infra.image_pull.fail_count` | counter | wrapper | Non-zero exit pulls |
| `infra.registry.error_rate` | gauge | access logs | 503 / total requests |
| `infra.image_pull.slow_pulls` | counter | wrapper | Pulls exceeding threshold |

### 4.4 Dimensions (labels for slicing)

- **image**: `postgres`, `redis`, `kyb-base`, etc.
- **tag**: `16-alpine`, `latest`, etc.
- **registry**: `docker.io`, `ghcr.io`, `localhost:5000`, etc.
- **cluster**: `mac-orbstack`, `aliyun`, `office`
- **boss_id**: individual boss hostname
- **cache_status**: `up_to_date`, `fresh_pull`, `partial_cache`, `unknown`
- **hour/day**: time granularity

---

## 5. Estimated Volume

| Table | Rows/day (est) | Per-row | Daily volume | Retention | Total |
|-------|---------------|---------|-------------|-----------|-------|
| `infra.image_pulls` | ~50 | ~200 B | ~10 KB | 90 days | ~0.9 MB |
| `infra.image_pull_layers` | ~500 (optional) | ~150 B | ~75 KB | 30 days | ~2.2 MB |
| `infra.registry_requests` | ~10,000 | ~200 B | ~2 MB | 14 days | ~28 MB |
| `infra.image_pull_hourly` | ~200 (aggregated) | ~100 B | ~20 KB | 90 days | ~1.8 MB |
| `infra.registry_cache_stats` | ~50 (daily) | ~100 B | ~5 KB | 365 days | ~1.8 MB |

**Total**: ~35 MB over retention period. Negligible for ClickHouse.

**Burst scenario** (sandbox creation creates many container pulls): During `kyb create`, kyb-base image + service images are pulled. If provisioning 10 sandboxes simultaneously, pull events spike to ~20-30 pulls in a short window. Still well within ClickHouse's ingestion capacity.

---

## 6. Grafana Dashboards

### 6.1 Pull Duration Overview

| Panel | Query | Description |
|-------|-------|-------------|
| Pull Duration P50/P90/P99 | `SELECT hour, registry, avg(p50_duration_ms), avg(p90_duration_ms), avg(p99_duration_ms) FROM infra.image_pull_hourly WHERE hour > now() - 7d GROUP BY hour, registry` | Multi-line time series, one series per percentile |
| Slowest Images (Table) | `SELECT image, registry, count() AS pulls, round(avg(avg_duration_ms)) AS avg_ms, round(max(max_duration_ms)) AS max_ms FROM infra.image_pull_hourly WHERE hour > now() - 7d GROUP BY image, registry ORDER BY avg_ms DESC LIMIT 20` | Ranked table of images by average pull time |
| Pull Duration Distribution | `SELECT round(pull_duration_ms / 1000) AS sec_bucket, count() FROM infra.image_pulls WHERE event_time > now() - 7d GROUP BY sec_bucket ORDER BY sec_bucket` | Histogram of pull durations |
| Pull Count by Registry | `SELECT registry, count() FROM infra.image_pulls WHERE event_time > now() - 7d GROUP BY registry` | Pie/bar chart of pull volume per registry |

### 6.2 Cache Efficiency

| Panel | Query | Description |
|-------|-------|-------------|
| Cache Hit Ratio (Time Series) | `SELECT hour, avg(avg_cache_hit_ratio) FROM infra.image_pull_hourly WHERE hour > now() - 7d GROUP BY hour ORDER BY hour` | Line chart — cache efficiency over time |
| Cache Hit by Image | `SELECT image, avg(avg_cache_hit_ratio) AS hit_ratio, sum(pull_count) AS pulls FROM infra.image_pull_hourly WHERE hour > now() - 7d GROUP BY image ORDER BY pulls DESC LIMIT 20` | Table — which images benefit most from cache |
| Blob Cache Hit from Registry | `SELECT day, avg(blob_hits / total_blob_requests) AS hit_ratio FROM infra.registry_cache_stats WHERE day > now() - 14d GROUP BY day ORDER BY day` | Registry-side cache hit ratio (cross-check with wrapper data) |
| Layers Cached vs Pulled | `SELECT hour, sum(total_layers_cached) AS cached, sum(total_layers_pulled) AS pulled FROM infra.image_pull_hourly WHERE hour > now() - 7d GROUP BY hour ORDER BY hour` | Stacked area chart |

### 6.3 Slow Pull Detection

| Panel | Query | Description |
|-------|-------|-------------|
| Slow Pulls (Table) | `SELECT event_time, image_full, registry, pull_duration_ms, cache_status, bytes_transferred, boss_id FROM infra.image_pulls WHERE pull_duration_ms > 30000 ORDER BY pull_duration_ms DESC LIMIT 50` | Pulls exceeding 30s threshold |
| Slow Pull Rate | `SELECT toStartOfHour(event_time) AS hour, countIf(pull_duration_ms > 30000) / count() AS slow_ratio FROM infra.image_pulls WHERE event_time > now() - 7d GROUP BY hour ORDER BY hour` | Proportion of pulls that are slow |
| Pull Failures | `SELECT event_time, image_full, registry, exit_code, error_message FROM infra.image_pulls WHERE exit_code != 0 AND event_time > now() - 7d ORDER BY event_time DESC LIMIT 50` | Failed pull details |

### 6.4 Registry Cache Health

| Panel | Query | Description |
|-------|-------|-------------|
| Registry Request Rate | `SELECT toStartOfMinute(event_time) AS minute, count() FROM infra.registry_requests WHERE event_time > now() - 1h GROUP BY minute ORDER BY minute` | Requests per minute |
| Status Breakdown | `SELECT status, count() FROM infra.registry_requests WHERE event_time > now() - 1h GROUP BY status` | Pie chart — HTTP status distribution |
| Upstream Errors | `SELECT toStartOfHour(event_time) AS hour, countIf(status = 503) AS upstream_errors FROM infra.registry_requests WHERE event_time > now() - 7d GROUP BY hour ORDER BY hour` | Time series of upstream registry failures |
| Top Images by Volume | `SELECT image_path, count() AS requests, sum(bytes_sent) AS total_bytes FROM infra.registry_requests WHERE event_time > now() - 24h AND request_type = 'blob' GROUP BY image_path ORDER BY requests DESC LIMIT 20` | Most requested images from cache |

---

## 7. Alert Rules

| Rule | Condition | Severity | Response |
|------|-----------|----------|----------|
| **SlowPull** | Any pull > 60s | P3 | Notify: "${image} pull took ${duration}s on ${cluster}" |
| **PullFailure** | Pull exit_code != 0 | P2 | Notify: "${image} pull failed on ${cluster}: ${error}" |
| **CacheHitRatioDrop** | Cache hit ratio drops below 0.5 for > 1h | P3 | Notify: "Cache efficiency dropped to ${ratio} on ${cluster} — registry may be misconfigured or cache volume full" |
| **RegistryUnreachable** | Registry 503 rate > 10% in 5 min | P2 | Notify: "Registry upstream unreachable on ${cluster} — Docker Hub may be down or proxy issue" |
| **BurstSlowPull** | More than 3 slow pulls (>30s) in 5 min | P2 | Notify: "Burst of slow pulls detected — possible bandwidth saturation on ${cluster}" |
| **NoPullData** | No pull events for > 24h from any cluster | P3 | Notify: "No pull data received — docker-pull-wrapper may not be installed or CK write path broken" |

### Alert Staging

1. **SlowPull + PullFailure** (immediate — wrapper must be deployed first)
2. **RegistryUnreachable** (after Vector registry log parsing is deployed)
3. **CacheHitRatioDrop** (needs baseline — deploy after 1 week of data)
4. **BurstSlowPull** (after threshold tuning with real data)
5. **NoPullData** (health check for the pipeline itself)

---

## 8. Implementation Checklist

### Phase 1: Wrapper Deployment (today, < 2h)

- [ ] Write `~/.kyb/bin/docker-pull` wrapper script (Section 2.2)
- [ ] Create `infra.image_pulls` table in ClickHouse
- [ ] Deploy wrapper to Mac/Orbstack boss; alias `docker pull` -> `docker-pull`
- [ ] Test: run `docker pull alpine:latest` and verify event lands in CK
- [ ] Deploy to Aliyun boss, Office boss
- [ ] Update `bin/kyb` and `lib/kyb/docker.rb` to call wrapper instead of direct `docker pull`

### Phase 2: Registry Access Logs (this week, < 1 day)

- [ ] Enable `$request_time` in registry access log format (`REGISTRY_HTTP_LOG_FIELDS`)
- [ ] Create `infra.registry_requests` table in ClickHouse
- [ ] Deploy Vector registry log parsing config (Section 2.1)
- [ ] Verify data flowing: registry -> Vector -> CK
- [ ] Create `infra.registry_cache_stats` materialized view

### Phase 3: Aggregation & Dashboard (this week, < 2h)

- [ ] Create `infra.image_pull_hourly` and `infra.registry_cache_stats` materialized views
- [ ] Build Grafana dashboard with panels from Section 6
- [ ] Verify dashboard renders with real data

### Phase 4: Alerts (next week, < 1h)

- [ ] Configure Grafana alerts for Stage 1 rules (SlowPull, PullFailure)
- [ ] Wire RegistryUnreachable alert (depends on Phase 2)
- [ ] Set up patrol integration: query slow pulls in 5-min patrol

### Phase 5: Deep Analytics (optional, after baseline)

- [ ] Deploy `infra.image_pull_layers` for per-layer analysis
- [ ] Build anomaly detection for pull duration (baseline-based, not fixed threshold)
- [ ] Integrate with sandbox provisioning: alert if `kyb create` is slow due to image pull
- [ ] Track pull cost: if registry has per-blob billing, track bytes_transferred per image

---

## 9. Design Decisions & Trade-offs

### Why not use Docker Engine API directly?

Docker Engine API `/images/create` does stream pull progress as JSON, but:
- Requires a persistent HTTP connection to the Docker socket
- The event stream does not include `request_time` or total duration in a single field
- Would require a long-running daemon (more infrastructure than a wrapper script)

The wrapper approach is simpler, zero-infrastructure (already runs inside bosses), and captures all needed data.

### Why two sources for cache hit ratio (wrapper + registry logs)?

They complement each other:
- **Wrapper** sees the full pull lifecycle: start to finish, per-image, cache status string from Docker
- **Registry logs** see every blob request and can detect true cache hits vs upstream fetches with byte-level accuracy
- Cross-referencing both sources validates accuracy

If they disagree (e.g., wrapper says "cached" but registry shows 404), it indicates:
- Cache invalidation issue (stale manifest)
- Registry GC deleted blobs but the manifest still exists
- Docker's layer cache on the host served the layer (filesystem cache, not registry cache)

### Why not monitor sandbox container pulls separately?

Sandbox containers are created via `kyb create` which uses the base image. Monitoring `kyb create` duration captures the full startup time (pull + create + configure). The pull portion is already captured by the wrapper when `kyb create` calls `docker pull`. If we want per-sandbox attribution, we can add a `sandbox_id` label to the pull event — future enhancement.

### Why short TTL on registry_requests (14 days)?

Raw registry access logs are high volume (~10k rows/day) and primarily useful for:
- Real-time cache hit analysis
- Debugging recent registry issues
- Aggregating into daily cache stats

The aggregated views (`infra.registry_cache_stats` at 365 days, `infra.image_pull_hourly` at 90 days) provide the trend data. Raw logs beyond 14 days are rarely queried.

---

## 10. Future Enhancements

- **Per-sandbox attribution**: Track which sandbox/kyb create invocation triggered each pull, for provisioning duration breakdown
- **Registry GC prediction**: Correlate cache miss ratio with registry disk usage to predict when GC is needed
- **Automatic cache warming**: Pre-pull frequently used images (postgres, redis, kyb-base) on slow clusters during low-usage periods
- **Registry disk pressure alert**: Alert when registry cache volume exceeds 80% capacity
- **Multi-registry support**: Track pulls from GHCR, Docker Hub, and private registries separately
- **Pull cost tracking**: For paid registries (Docker Hub Pro, GitHub Packages), track bytes_transferred for cost allocation
- **Bandwidth saturation detection**: Combine pull speed from multiple concurrent pulls to detect when the link is saturated (correlate with sing-box traffic metrics)
- **Sandbox image pre-seeding**: When a new kyb-base image is built, proactively push it to slow clusters' registry caches before sandbox creation requests arrive

---

## 11. References

- [Docker Event Stream](https://docs.docker.com/engine/api/sdk/examples/#docker-events)
- [Docker Registry Pull-Through Cache](../handbook/registry-cache-deploy.md)
- [Docker Event Monitoring for Infra Containers](./docker-events.md) -- prior art for Docker event collection pattern
- [Docker Registry Logging](https://docs.docker.com/registry/configuration/#log)
- [Sing-Box Traffic Monitoring](./sing-box-metrics.md) -- bandwidth correlation for slow pull root cause analysis
- [Observability Design](../observability-design.md)
- [ClickHouse HTTP Interface](https://clickhouse.com/docs/en/interfaces/http)

> /人◕ ‿‿ ◕人＼
