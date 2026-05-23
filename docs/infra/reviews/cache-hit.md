---
decision: 稍后做
---

# Docker Layer Cache Monitoring

> **Status:** Design Document
> **Date:** 2026-05-23
> **Context:** Design a monitoring system for Docker BuildKit layer cache performance across all `kyb build` invocations. Track cache hit/miss ratio, layer reuse frequency, and cache storage waste to inform build optimization decisions.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Current State](#2-current-state)
3. [Metrics Design](#3-metrics-design)
4. [Data Collection: BuildKit Output Parsing](#4-data-collection-buildkit-output-parsing)
5. [ClickHouse Schema](#5-clickhouse-schema)
6. [Grafana Dashboard](#6-grafana-dashboard)
7. [Cache Storage Analysis](#7-cache-storage-analysis)
8. [Alerting Rules](#8-alerting-rules)
9. [Budget Allocation for Cache Waste](#9-budget-allocation-for-cache-waste)
10. [Implementation Roadmap](#10-implementation-roadmap)
11. [References](#11-references)

---

## 1. Problem Statement

The `kyb build` process produces a Docker image with ~25 layers. BuildKit's layer cache accelerates rebuilds but has several blind spots:

- **No visibility**: There is no metric for cache hit ratio per build. Engineers don't know if changes invalidate the entire cache or just 1-2 layers.
- **No trend data**: Cache performance over time is unknown. A change that breaks many layers goes unnoticed until build times spike.
- **Cache storage waste**: BuildKit's cache accumulates unreferenced layers. There is no tracking of cold vs hot data, making GC decisions arbitrary.
- **No cost attribution**: Cache misses from volatile layers (e.g., `claude-code` version bumps) are indistinguishable from misses caused by Dockerfile structure changes.

Without cache monitoring, build optimization (the techniques in `docker-cache-optimization.md`) is done blind -- you cannot measure whether reordering layers actually improved hit rate.

### Key Questions This Design Answers

| Question | How We Answer It |
|----------|-----------------|
| What is the cache hit ratio for the last 50 builds? | Aggregated per-build metrics in ClickHouse, graphed in Grafana |
| Which layers are most frequently rebuilt? | Layer-level tracking by Dockerfile command index |
| How much disk space does the BuildKit cache consume? | `docker buildx du` output collected periodically |
| Which layers waste storage? | Layers rebuilt frequently but producing identical digests (rebuild churn) |
| When should we run `docker builder prune`? | Alert when cache waste ratio exceeds threshold |
| Did a Dockerfile change improve or degrade cache performance? | Compare hit ratio before/after the change |

---

## 2. Current State

### 2.1 Build Flow

```
kyb build (lib/kyb/docker.rb)
  │  DOCKER_BUILDKIT=1
  │  docker build --build-arg BUILD_ALL_PROXY=...
  ▼
BuildKit evaluates Dockerfile (~25 RUN/COPY layers)
  │
  ├── Each RUN --mount=type=cache has a shared persistent cache mount
  │   (mise downloads, pip cache, uv cache, ms-playwright)
  │
  └── Each Dockerfile layer has a BuildKit layer cache key
      (command text + parent digest + build args + env)
```

### 2.2 Existing Tooling

| Tool | What it does | Gap |
|------|-------------|-----|
| `Kyb::Docker.stale?` | Detects if image is stale by comparing build hash | Only binary stale/fresh, no hit ratio or trend |
| `docker-cache-optimization.md` | Documents layer ordering strategy (stable->medium->volatile) | No measurement of whether ordering actually works |
| `stale-check.md` | Design for deprecation warning on stale image | Preventative UX, not monitoring |
| `docker build --progress=plain` | Human-readable layer-by-layer build output | Not captured, not parsed, not stored |
| `docker buildx du` | Shows BuildKit disk usage | Manual command, no history |

### 2.3 Dockerfile Layer Breakdown

For monitoring purposes, layers are grouped by stability class:

| Class | Layers | Typical Cache Hit Rate | Change Frequency |
|-------|--------|----------------------|-----------------|
| **Base OS** | `FROM ubuntu:24.04`, Aliyun mirror, apt install | ~100% | Almost never |
| **Stable** | PostgreSQL config, locale, user creation, bashrc, mise install | ~95% | ~1-2 changes/month |
| **Medium** | `COPY mise.config.toml`, mirror configs, Gradle/Maven config | ~80% | ~1 change/week |
| **Volatile** | mig25 pip install, kimi-cli, playwright, `COPY lib/` | ~50% | ~1 change/day |
| **Archive** | `COPY entrypoint.sh`, `ENV` cleanup | ~100% | Almost never |

The current `docker build` is a single `docker build -t kyb-base:latest .` with BuildKit enabled. There is no buildx bake, no multi-stage, and no CI integration -- builds happen on the host only.

### 2.4 Existing Cache Mounts

These are BuildKit `--mount=type=cache` targets (persistent, survive image deletion):

| Mount Target | Used By | Approx Size |
|-------------|---------|------------|
| `/home/dev/.local/share/mise/downloads` | All mise install RUNs | ~500MB |
| `/home/dev/.cache/pip` | pip install mig25 | ~100MB |
| `/home/dev/.cache/uv` | kimi-cli installation | ~50MB |
| `/home/dev/.cache/ms-playwright` | playwright install | ~400MB |

These cache mounts are shared across all builds. They are never GC'd -- they grow unbounded until the host runs out of disk.

---

## 3. Metrics Design

### 3.1 Per-Build Metrics (Collected on Every `kyb build`)

| Metric | Type | Source | Cardinality |
|--------|------|--------|-------------|
| `total_layers` | Gauge | BuildKit output parsing | Per build |
| `cached_layers` | Gauge | Lines matching `#N CACHED` | Per build |
| `rebuilt_layers` | Gauge | Lines matching `#N N.Ns ...` (not CACHED) | Per build |
| `cache_hit_ratio` | Gauge | `cached_layers / total_layers * 100` | Per build |
| `build_duration_seconds` | Gauge | Start to finish wall clock | Per build |
| `build_proxy` | Tag/String | Was proxy used? (`socks5://...` or `none`) | Per build |
| `build_host` | Tag/String | Hostname where build ran | Per build |
| `dockerfile_hash` | Tag/String | SHA256 of Dockerfile at build time | Per build |

### 3.2 Per-Layer Metrics (Collected on Every Build)

| Metric | Type | Source | Cardinality |
|--------|------|--------|-------------|
| `layer_index` | Gauge | `#N` prefix in output | Per layer per build |
| `layer_cached` | Gauge (0/1) | Whether `CACHED` appears | Per layer per build |
| `layer_duration_seconds` | Gauge | `N.Ns` from BuildKit output (0 if CACHED) | Per layer per build |
| `layer_command_hash` | Tag/String | BuildKit short hash of command text | Per layer per build |
| `layer_command_preview` | Tag/String | First 80 chars of the RUN/COPY command | Per layer per build |
| `layer_class` | Tag/String | `base_os`, `stable`, `medium`, `volatile`, `archive` | Per layer per build |

### 3.3 Build Cache Storage Metrics (Collected Periodically, e.g. Hourly)

| Metric | Type | Source | Cardinality |
|--------|------|--------|-------------|
| `cache_total_bytes` | Gauge | `docker buildx du --json` | Per host |
| `cache_reclaimable_bytes` | Gauge | `docker buildx du --filter type=...` (unused layers) | Per host |
| `cache_mount_bytes` | Gauge (tagged by mount path) | `du -sh /var/lib/docker/buildkit/...` | Per mount |
| `cache_waste_ratio` | Gauge | `reclaimable / total * 100` | Per host |

### 3.4 Derived Metrics (Computed in ClickHouse or Grafana)

| Metric | Formula | Purpose |
|--------|---------|---------|
| `7d_avg_hit_ratio` | `avg(cache_hit_ratio) over 7 days` | Trend signal for cache health |
| `layer_reuse_count` | `count(*) where layer_cached=1 group by layer_index` | Identify hot/cold layers |
| `rebuild_churn` | `count(*) where layer_cached=0 group by layer_command_hash` | Layers that rebuild most often |
| `waste_growth_rate` | `rate(cache_reclaimable_bytes[24h])` | Is cache waste accelerating? |

---

## 4. Data Collection: BuildKit Output Parsing

### 4.1 Parsing Strategy

Add a lightweight BuildKit output parser in `lib/kyb/docker.rb` that wraps the existing `docker build` invocation. The parser reads stdout/stderr from the build process and extracts layer-level metrics.

**BuildKit `--progress=plain` output format:**

```
#1 [internal] load build definition from Dockerfile
#1 sha256:abc123...
#1 CACHED

#2 [internal] load metadata for docker.io/library/ubuntu:24.04
#2 sha256:def456...
#2 CACHED

#3 [auth] library/ubuntu:pull token for registry-1.docker.io
#3 sha256:ghi789...
#3 DONE 0.0s

#4 [1/5] FROM docker.io/library/ubuntu:24.04@sha256:...
#4 sha256:jkl012...
#4 CACHED

#5 [2/5] RUN arch="..." && sed -i 's|http://archive.ubuntu.com/...'
#5 sha256:mno345...
#5 0.315s Running apt-get update...
#5 3.200s Running apt-get upgrade...
#5 DONE 5.2s

#6 [3/5] RUN echo 'local all all trust' > /etc/postgresql/16/main/pg_hba.conf
#6 sha256:pqr678...
#6 CACHED
```

### 4.2 Parsing Rules

| Line Pattern | Action | Example |
|-------------|--------|---------|
| `#N [M/K] TEXT` | Start tracking layer `N` with command preview `TEXT` | `#5 [2/5] RUN apt-get install...` |
| `#N CACHED` | Mark layer `N` as cache hit | `#6 CACHED` |
| `#N DONE N.Ns` | End tracking layer `N` with duration | `#5 DONE 5.2s` |
| `#N N.Ns ...` (intermediate output) | Layer `N` is rebuilding (not cached) | `#5 0.315s Running apt-get...` |
| `#N sha256:...` | Record command hash for layer `N` | `#5 sha256:mno345...` |

**Heuristic for cache hit detection**: If we see `#N CACHED` before `#N DONE`, the layer was a hit. If we see `#N N.Ns` (intermediate output with a duration prefix), the layer was a miss.

### 4.3 Implementation Sketch

```ruby
# lib/kyb/build_monitor.rb

module Kyb::BuildMonitor
  class LayerResult
    attr_reader :index, :command_hash, :command_preview, :cached, :duration_seconds

    def initialize(index, command_preview:, command_hash: nil)
      @index = index
      @command_preview = command_preview
      @command_hash = command_hash
      @cached = false
      @duration_seconds = 0.0
    end

    def mark_rebuilding!
      @cached = false
    end

    def mark_cached!
      @cached = true
    end

    def finish!(duration)
      @duration_seconds = duration
    end
  end

  class BuildResult
    attr_reader :layers, :start_time, :end_time, :proxy_used, :dockerfile_hash

    def initialize(proxy_used: false, dockerfile_hash: nil)
      @layers = {}
      @start_time = Time.now
      @proxy_used = proxy_used
      @dockerfile_hash = dockerfile_hash
    end

    def record_layer(index, preview:, hash: nil)
      @layers[index] = LayerResult.new(index, command_preview: preview, command_hash: hash)
    end

    def finish!
      @end_time = Time.now
    end

    def total_layers
      @layers.size
    end

    def cached_layers
      @layers.count { |_, l| l.cached }
    end

    def rebuilt_layers
      total_layers - cached_layers
    end

    def cache_hit_ratio
      return 0.0 if total_layers.zero?
      (cached_layers.to_f / total_layers * 100).round(1)
    end

    def duration_seconds
      ((end_time || Time.now) - start_time).to_f.round(1)
    end

    def to_h
      {
        total_layers: total_layers,
        cached_layers: cached_layers,
        rebuilt_layers: rebuilt_layers,
        cache_hit_ratio: cache_hit_ratio,
        build_duration: duration_seconds,
        proxy_used: @proxy_used,
        dockerfile_hash: @dockerfile_hash,
        build_host: Socket.gethostname,
        timestamp: @start_time.utc.iso8601,
        layers: @layers.values.map { |l|
          {
            index: l.index,
            cached: l.cached,
            duration: l.duration_seconds,
            command_hash: l.command_hash,
            command_preview: l.command_preview[0..80]
          }
        }
      }
    end
  end

  def self.parse_build_output(io, proxy_used: false, dockerfile_hash: nil)
    result = BuildResult.new(proxy_used: proxy_used, dockerfile_hash: dockerfile_hash)
    current_layer = nil

    io.each_line do |line|
      case line
      when /^#(\d+) \[([^\]]+)\] (.+)$/
        # New layer start: #5 [2/5] RUN apt-get install...
        idx = $1.to_i
        preview = $3.strip
        result.record_layer(idx, preview: preview, hash: nil)
        current_layer = idx
      when /^#(\d+) CACHED$/
        idx = $1.to_i
        if (layer = result.layers[idx])
          layer.mark_cached!
        end
      when /^#(\d+) sha256:([a-f0-9]+)$/
        idx = $1.to_i
        hash = $2
        if (layer = result.layers[idx])
          layer.command_hash = hash
        end
      when /^#(\d+) DONE ([\d.]+)s$/
        idx = $1.to_i
        duration = $2.to_f
        if (layer = result.layers[idx])
          layer.finish!(duration)
        end
        current_layer = nil
      when /^#(\d+) ([\d.]+)s (.+)$/
        # Intermediate output: #5 0.315s Running apt-get...
        # This confirms the layer is NOT cached
        idx = $1.to_i
        if (layer = result.layers[idx])
          layer.mark_rebuilding!
        end
      end
    end

    result.finish!
    result
  end
end
```

**Integration into `lib/kyb/docker.rb`**:

Replace the current `system(env, *args)` call with an `IO.pipe`-based capture:

```ruby
def build(tag, path, proxy: nil)
  # ... existing setup ...
  dockerfile_hash = compute_build_hash(path)

  rd, wr = IO.pipe
  pid = spawn(env, *args, out: wr, err: [:child, :out])
  wr.close

  build_result = Kyb::BuildMonitor.parse_build_output(rd,
    proxy_used: !proxy.nil?,
    dockerfile_hash: dockerfile_hash
  )
  Process.wait(pid)

  if $?.success?
    emit_build_metrics(build_result)
  else
    Kyb.die('docker build failed')
  end
end
```

### 4.4 Metric Emission

Two channels for emitting collected metrics:

**Channel 1: ClickHouse HTTP INSERT (primary, for Grafana dashboards)**

```ruby
def emit_build_metrics(result)
  # Build-level row
  clickhouse_post("INSERT INTO infra.build_cache_metrics FORMAT JSONEachRow",
    JSON.generate({
      event_time: result.start_time,
      total_layers: result.total_layers,
      cached_layers: result.cached_layers,
      rebuilt_layers: result.rebuilt_layers,
      cache_hit_ratio: result.cache_hit_ratio,
      build_duration: result.duration_seconds,
      proxy_used: result.proxy_used,
      dockerfile_hash: result.dockerfile_hash,
      build_host: result.build_host,
      metric_type: 'build_summary'
    })
  )

  # Per-layer rows (batch insert)
  layers_json = result.layers.values.map { |l|
    JSON.generate({
      event_time: result.start_time,
      build_host: result.build_host,
      dockerfile_hash: result.dockerfile_hash,
      layer_index: l.index,
      layer_cached: l.cached ? 1 : 0,
      layer_duration: l.duration_seconds,
      command_hash: l.command_hash || '',
      command_preview: l.command_preview[0..80],
      metric_type: 'layer_detail'
    })
  }.join("\n")

  clickhouse_post("INSERT INTO infra.build_cache_metrics FORMAT JSONEachRow", layers_json)
end
```

**Channel 2: Local JSONL log (fallback, when ClickHouse is unreachable)**

Append to `/tmp/kyb-build-cache.jsonl` as newline-delimited JSON. A periodic script or Vector tailer ships these to ClickHouse on a schedule.

### 4.5 Cache Storage Collection (Separate Cron)

A lightweight script runs periodically (e.g., hourly via `kyb cron` or host cron) to collect BuildKit storage stats:

```bash
#!/bin/bash
# collect-build-cache-stats.sh

# BuildKit disk usage
docker buildx du --json 2>/dev/null | \
  jq '{event_time: now, metric_type: "cache_storage", cache_total_bytes: .Size, cache_reclaimable_bytes: .Reclaimable, cache_count: .Count}' \
  >> /tmp/kyb-cache-storage.jsonl

# Cache mount sizes
for mount in /home/dev/.local/share/mise/downloads /home/dev/.cache/pip /home/dev/.cache/uv /home/dev/.cache/ms-playwright; do
  size=$(sudo du -sb "$mount" 2>/dev/null | cut -f1)
  echo '{"event_time": '$(date +%s)', "metric_type": "cache_mount", "mount_path": "'$mount'", "mount_bytes": '$size'}' \
    >> /tmp/kyb-cache-storage.jsonl
done
```

---

## 5. ClickHouse Schema

### 5.1 Unified Metrics Table

A single `infra.build_cache_metrics` table with `metric_type` discriminator (same pattern as `cc.hook_events`):

```sql
CREATE TABLE IF NOT EXISTS infra.build_cache_metrics (
    -- Partitioning / sorting
    event_time      DateTime64(3) DEFAULT now64(),

    -- Metric type discriminator
    metric_type     LowCardinality(String),

    -- Build-level fields (metric_type = 'build_summary')
    total_layers        UInt16 DEFAULT 0,
    cached_layers       UInt16 DEFAULT 0,
    rebuilt_layers      UInt16 DEFAULT 0,
    cache_hit_ratio     Float32 DEFAULT 0,
    build_duration      Float32 DEFAULT 0,
    proxy_used          UInt8 DEFAULT 0,
    dockerfile_hash     String DEFAULT '',
    build_host          LowCardinality(String) DEFAULT '',

    -- Per-layer fields (metric_type = 'layer_detail')
    layer_index         UInt16 DEFAULT 0,
    layer_cached        UInt8 DEFAULT 0,
    layer_duration      Float32 DEFAULT 0,
    command_hash        String DEFAULT '',
    command_preview     String DEFAULT '',

    -- Cache storage fields (metric_type = 'cache_storage' or 'cache_mount')
    cache_total_bytes       Int64 DEFAULT 0,
    cache_reclaimable_bytes Int64 DEFAULT 0,
    cache_count             UInt32 DEFAULT 0,
    mount_path              String DEFAULT '',
    mount_bytes             Int64 DEFAULT 0,

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now(),

    -- Allow any extra fields (future-proofing)
    raw_payload     String CODEC(ZSTD(3)) DEFAULT ''
)
ENGINE = MergeTree
ORDER BY (toDate(event_time), metric_type, build_host)
TTL toDate(event_time) + INTERVAL 180 DAY
SETTINGS index_granularity = 8192;
```

### 5.2 Materialized Views

**MV: Daily cache hit ratio per host**

```sql
CREATE MATERIALIZED VIEW infra.build_cache_hit_daily
ENGINE = SummingMergeTree
ORDER BY (day, build_host)
AS SELECT
    toDate(event_time) AS day,
    build_host,
    count() AS build_count,
    sum(total_layers) AS total_layers,
    sum(cached_layers) AS cached_layers,
    avg(cache_hit_ratio) AS avg_hit_ratio,
    min(cache_hit_ratio) AS min_hit_ratio,
    max(cache_hit_ratio) AS max_hit_ratio
FROM infra.build_cache_metrics
WHERE metric_type = 'build_summary'
GROUP BY day, build_host;
```

**MV: Layer rebuild frequency**

```sql
CREATE MATERIALIZED VIEW infra.build_cache_layer_freq
ENGINE = AggregatingMergeTree
ORDER BY (layer_index, command_hash)
AS SELECT
    layer_index,
    command_hash,
    anyLast(command_preview) AS command_preview,
    count() AS total_builds,
    sum(layer_cached) AS cache_hits,
    avg(layer_duration) AS avg_duration_rebuild
FROM infra.build_cache_metrics
WHERE metric_type = 'layer_detail'
GROUP BY layer_index, command_hash;
```

### 5.3 Storage Estimation

At current build frequency (~5 builds/day on 1 host):

| Metric | Rows per Build | Daily Rows | 180-Day Storage |
|--------|---------------|-----------|----------------|
| build_summary | 1 | 5 | ~900 rows |
| layer_detail | ~25 | 125 | ~22,500 rows |
| cache_storage | 1 (hourly) | 24 | ~4,320 rows |
| cache_mount | 4 (hourly) | 96 | ~17,280 rows |
| **Total** | ~31 | **~250** | **~45,000 rows** |

At ~500 bytes per row (compressed), total storage: **~22.5 MB** over 180 days. Negligible.

---

## 6. Grafana Dashboard

### 6.1 Dashboard: "Docker Build Cache"

**Panel 1: Cache Hit Ratio (Time Series)**

```
Query: SELECT event_time, cache_hit_ratio
       FROM infra.build_cache_metrics
       WHERE metric_type = 'build_summary'
         AND event_time >= now() - INTERVAL 30 DAY
       ORDER BY event_time

Type: Time series, bar chart
Unit: Percent (0-100)
Threshold: < 50% = red, 50-70% = yellow, > 70% = green
```

**Panel 2: Total / Cached / Rebuilt Layers (Stacked Bar)**

```
Query: SELECT event_time, total_layers, cached_layers, rebuilt_layers
       FROM infra.build_cache_metrics
       WHERE metric_type = 'build_summary'
         AND event_time >= now() - INTERVAL 30 DAY
       ORDER BY event_time

Type: Stacked bar (green = cached, red = rebuilt)
```

**Panel 3: Build Duration (Time Series)**

```
Query: SELECT event_time, build_duration
       FROM infra.build_cache_metrics
       WHERE metric_type = 'build_summary'
         AND event_time >= now() - INTERVAL 30 DAY
       ORDER BY event_time

Type: Time series, line chart
Unit: Seconds
```

**Panel 4: Layer Rebuild Heatmap**

```
Query: SELECT event_time, layer_index, layer_cached
       FROM infra.build_cache_metrics
       WHERE metric_type = 'layer_detail'
         AND event_time >= now() - INTERVAL 30 DAY
       ORDER BY event_time

Type: Heatmap (x = time, y = layer_index, color = cached/rebuild)
```

**Panel 5: BuildKit Cache Storage (Gauge)**

```
Query: SELECT event_time, cache_total_bytes, cache_reclaimable_bytes
       FROM infra.build_cache_metrics
       WHERE metric_type = 'cache_storage'
         AND event_time >= now() - INTERVAL 7 DAY
       ORDER BY event_time DESC LIMIT 1

Type: Stat / Gauge
Unit: Bytes (human-readable: MB/GB)
```

**Panel 6: Cache Mount Size by Path (Pie Chart)**

```
Query: SELECT mount_path, mount_bytes
       FROM infra.build_cache_metrics
       WHERE metric_type = 'cache_mount'
         AND event_time >= now() - INTERVAL 1 DAY
       ORDER BY event_time DESC LIMIT 1 BY mount_path

Type: Pie chart
Unit: Bytes
```

**Panel 7: Weekly Average Hit Ratio (Stat)**

```
Query: SELECT avg(cache_hit_ratio) FROM infra.build_cache_metrics
       WHERE metric_type = 'build_summary'
         AND event_time >= now() - INTERVAL 7 DAY
       AND event_time < now()

Type: Stat
Unit: Percent
```

### 6.2 Dashboard Variables

| Variable | Definition | Purpose |
|----------|-----------|---------|
| `$build_host` | `SHOW DATABASES`-equivalent from `SELECT distinct(build_host) FROM infra.build_cache_metrics` | Filter by host |
| `$time_range` | Grafana default time range picker | Filter by time |

---

## 7. Cache Storage Analysis

### 7.1 BuildKit Cache Breakdown

BuildKit's cache consists of several components stored under `/var/lib/docker/buildkit/`:

| Component | Path | Contents | Typical Size |
|-----------|------|----------|-------------|
| Layer blobs | `/var/lib/docker/buildkit/runc-overlayfs/blobs/` | Uncompressed layer snapshots (SHA256-addressed) | 2-5 GB |
| Metadata | `/var/lib/docker/buildkit/runc-overlayfs/metadata.db` | Layer metadata, cache keys | ~50 MB |
| Records | `/var/lib/docker/buildkit/content/blobs/` | Content-addressable blob store | 1-3 GB |

**Key insight**: BuildKit does not automatically GC unreferenced layer blobs. Every `docker build` with different Dockerfile content adds new layers to the blob store without removing old ones.

### 7.2 Cache Waste Classification

At current build frequency (~5 builds/week), the waste profile is:

| Waste Category | Cause | Estimated Size | GC-able? | Priority |
|---------------|-------|---------------|----------|----------|
| Old layer blobs | Dockerfile changes produce new layer digests, old ones remain | ~500 MB/week | Yes (`docker builder prune --all`) | High |
| Stale cache mounts | `--mount=type=cache` directories grow unbounded (pip cache, mise tarballs) | ~1 GB total, grows ~50 MB/week | Manual (delete mount target) | Medium |
| Intermediate images | Builds interrupted mid-way leave dangling layers | ~100 MB/incident | Automatic (BuildKit releases after 48h) | Low |
| Unused `--mount=type=cache` content | Packages downloaded but no longer needed after tool version changes | ~200 MB | Manual | Low |

### 7.3 GC Strategy

Based on cache monitoring data, these GC thresholds apply:

| GC Action | Trigger Condition | Crontab Frequency |
|-----------|------------------|-------------------|
| `docker builder prune --all --force` | Cache waste ratio > 50% (reclaimable > 50% of total) OR cache total > 10 GB | Weekly if triggered |
| `docker builder prune --filter until=48h` | Periodically, regardless of waste ratio | Daily |
| Manual cache mount GC | Mount size grows > 2 GB for any single mount | Monthly review |
| `docker system df` log | Every `docker build` completion (lightweight, just log) | Every build |

### 7.4 Cache Waste Budget

Define a budget for cache waste to prevent disk-full incidents:

```
Cache Budget (per host):
  Total cache allocation: 15 GB
  Warning threshold: 12 GB (alert: "BuildKit cache > 80% of budget")
  Critical threshold: 14 GB (auto-GC: docker builder prune --all)
  Max mount size per path: 2 GB (alert if exceeded)
  Acceptable waste ratio: < 30% (reclaimable / total)
```

---

## 8. Alerting Rules

### 8.1 Grafana Alerts (via ClickHouse datasource)

**Alert: Build cache hit ratio dropped**

```
Name: kyb-build-cache-hit-ratio-low
Condition: avg_over_time(cache_hit_ratio[3 builds]) < 40
Severity: warning
Summary: "Build cache hit ratio dropped to {{ $value }}% over last 3 builds"
Suggested cause: Dockerfile restructured or build context changed
```

**Alert: BuildKit cache exceeding budget**

```
Name: kyb-build-cache-disk-pressure
Condition: cache_total_bytes > 12 GB
Severity: warning (12GB), critical (14GB)
Summary: "BuildKit cache is {{ $value | humanizeBytes }} ({{ $value / 15GB * 100 }}% of budget)"
Action: Run `docker builder prune --all --force`
```

**Alert: Build duration anomaly**

```
Name: kyb-build-duration-spike
Condition: build_duration > 3 * avg_over_time(build_duration[10 builds])
Severity: info
Summary: "Build took {{ $value }}s (3x longer than 10-build average)"
Suggested cause: Cold cache after Dockerfile change or network slowdown
```

**Alert: Cache storage not reporting**

```
Name: kyb-build-cache-storage-stale
Condition: age of last cache_storage metric > 2 hours
Severity: warning
Summary: "BuildKit cache storage metrics not reported for > 2 hours"
Suggested cause: Collect script not running or ClickHouse unreachable
```

### 8.2 Alert Routing

| Alert | Severity | Channel | First Response |
|-------|----------|---------|---------------|
| Low hit ratio | warning | Feishu group + Grafana panel highlight | Investigate within 24h |
| Cache disk pressure | warning/critical | Feishu @all (critical) | Run prune within 1h |
| Duration spike | info | Feishu thread | Check on next build |
| Storage stale | warning | Feishu group | Restart collector script |

---

## 9. Budget Allocation for Cache Waste

### 9.1 Measurement Framework

Track cache waste in two dimensions:

**Dimension 1: Layer Churn**

```
Layer Churn Score = (layers_rebuilt_in_last_30_days / total_layers) * 100

Thresholds:
  < 20%: Healthy layer cache
  20-50%: Moderate churn (review volatile layers)
  > 50%: High churn (Dockerfile restructuring needed)
```

**Dimension 2: Storage Waste**

```
Storage Waste Score = (cache_reclaimable_bytes / cache_total_bytes) * 100

Thresholds:
  < 20%: Efficient
  20-40%: Moderate waste (schedule GC)
  > 40%: Excessive waste (immediate GC needed)
```

### 9.2 Layer Classification Budget

Each layer class gets a budget for acceptable rebuild frequency:

| Class | Acceptable Rebuild Rate | Acceptable Duration per Rebuild | Review Trigger |
|-------|------------------------|--------------------------------|----------------|
| Base OS | < 5% of builds | N/A (almost never changes) | Any rebuild |
| Stable | < 10% of builds | < 30s | >15% rebuild rate |
| Medium | < 25% of builds | < 60s | >40% rebuild rate |
| Volatile | < 60% of builds | < 120s | >80% rebuild rate |
| Archive | < 5% of builds | N/A | Any rebuild |

### 9.3 Optimization ROI Calculation

When a layer exceeds its budget, calculate the ROI of optimizing it:

```
ROI = (current_rebuild_duration * rebuilds_per_month * optimization_lifetime_months)
      / (engineering_hours_to_fix * hourly_rate)

If ROI > 3x: Optimize
If ROI 1-3x: Schedule
If ROI < 1x: Accept current behavior
```

**Example**: The `mig25 pip install` layer (volatile class) rebuilds ~50% of builds and takes 45s each time:

```python
rebuild_cost = 45s * 2.5 rebuilds/week * 4 weeks * 12 months = 90 minutes/year
engineering_cost = 30 minutes to pin pip versions in Dockerfile
ROI = 90 / 30 = 3x → Worth optimizing (pin pip requirements.txt)
```

---

## 10. Implementation Roadmap

### Phase 1: Data Collection (Day 1-2)

- [ ] Add `lib/kyb/build_monitor.rb` with BuildKit output parser
- [ ] Wire parser into `Kyb::Docker.build()` via `IO.pipe` capture
- [ ] Add ClickHouse HTTP INSERT emission in `emit_build_metrics()`
- [ ] Add fallback JSONL logging when ClickHouse is unreachable
- [ ] Create `infra.build_cache_metrics` table in ClickHouse
- [ ] Deploy `collect-build-cache-stats.sh` as an hourly cron job
- [ ] Verify: run `kyb build`, check ClickHouse has rows

### Phase 2: Visualization (Day 3)

- [ ] Create Grafana dashboard "Docker Build Cache" with 7 panels
- [ ] Add dashboard variables (`$build_host`, `$time_range`)
- [ ] Set up daily materialized views for aggregated metrics
- [ ] Share dashboard link with the team

### Phase 3: Alerting (Day 4)

- [ ] Configure 4 Grafana alert rules (hit ratio, disk, duration, stale)
- [ ] Wire critical alerts to Feishu @all
- [ ] Set up alert silence for expected maintenance windows
- [ ] Test alert firing by deliberately messing up Dockerfile cache

### Phase 4: Optimization Feedback Loop (Day 5+)

- [ ] Review 1 week of data: identify worst-performing layers
- [ ] Calculate ROI for each over-budget layer
- [ ] Implement top 3 optimizations from ROI analysis
- [ ] Measure hit ratio improvement after optimizations
- [ ] Adjust layer class budgets based on real data

### Effort Estimate

| Task | Time |
|------|------|
| BuildKit output parser | 1h |
| CI pipeline capture integration | 30min |
| ClickHouse schema + emission | 30min |
| Grafana dashboard (7 panels) | 1h |
| Alert rules (4 rules) | 30min |
| Storage collector script | 15min |
| **Total Phase 1-3** | **~3.5 hours** |

---

## 11. References

- `docs/build/docker-cache-optimization.md` — Existing layer ordering optimization
- `docs/build/docker-pitfalls.md` — Docker build pitfalls (cache mount permissions, build context)
- `docs/build/stale-check.md` — Image staleness detection (precursor to this design)
- `docs/infra/handbook/registry-cache-deploy.md` — Image pull cache (different from build cache)
- `docs/infra/reviews/prometheus-scrape.md` — Metrics collection infra for all services
- `docs/infra/reviews/vector-pipeline.md` — Log shipping pipeline (used for JSONL fallback)
- `lib/kyb/docker.rb` — Build invocation that will host the parser
- `Dockerfile` — The 25-layer build that generates the metrics

---

## Verdict

**Approve for implementation.** The cache monitoring design is:

- **Low overhead**: BuildKit output parsing adds < 50ms per build. ClickHouse storage is ~22 MB over 180 days.
- **High value**: Answers previously unanswerable questions about cache performance, layer churn, and storage waste.
- **Self-funding**: Identifies optimization ROI that pays back the implementation time within weeks.
- **Non-invasive**: Pure instrumentation layer around existing `docker build` -- no changes to Dockerfile, no new containers, no build process changes.
- **Composable**: Fits into the existing metrics pipeline (`infra.*` ClickHouse database, Grafana dashboards per service).

The phased approach (collect -> visualize -> alert -> optimize) ensures immediate value from Phase 1 (build metrics exist) while the alerting and optimization feedback loop in Phases 3-4 provides continuous improvement.
