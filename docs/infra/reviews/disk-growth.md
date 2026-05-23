---
decision: 稍后做
---

# Disk Growth Monitoring

> **Status:** Design Document
> **Date:** 2026-05-23
> **Context:** Track disk usage trends across all clusters, predict exhaustion dates, and alert before disks fill up.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Current State](#2-current-state)
3. [Design](#3-design)
4. [ClickHouse Schema](#4-clickhouse-schema)
5. [Collection Script](#5-collection-script)
6. [Exhaustion Prediction](#6-exhaustion-prediction)
7. [Alert Thresholds](#7-alert-thresholds)
8. [Grafana Dashboard](#8-grafana-dashboard)
9. [Integration with Existing Systems](#9-integration-with-existing-systems)
10. [Rollout Plan](#10-rollout-plan)

---

## 1. Problem Statement

The multi-cluster infra has three nodes with different disk sizes and growth profiles:

| Cluster | Host | Disk | Total |
|---------|------|------|-------|
| Mac/Orbstack | dongqs-mac | Mac SSD | ~260 GiB |
| Aliyun | sim | 40 GiB ESSD | ~40 GiB |
| Office | nuc8 | NUC SSD | ~256 GiB |

The heartbeat system already collects `disk_used_pct` once per 60s, but:

1. **No trend tracking** -- a single percentage tells you the current state but not whether disk is growing or stable.
2. **No exhaustion prediction** -- you don't know when disk will fill up.
3. **No differentiated thresholds** -- 40 GiB on sim and 260 GiB on Mac need different alert levels (10% on sim is 4 GiB, same as 1.5% on Mac).
4. **No historical storage** -- heartbeats use ReplacingMergeTree with no TTL, but the schema lacks fields for precise tracking (total bytes, used bytes, available bytes, inode usage).

### What We Need

- Track `disk_total_bytes`, `disk_used_bytes`, `disk_avail_bytes` per cluster per interval.
- Compute daily growth rate (bytes/day) using linear regression on the time series.
- Predict exhaustion date: when `disk_used_bytes + (growth_rate * days)` reaches `disk_total_bytes`.
- Alert at warning (e.g., <30 days) and critical (e.g., <7 days) thresholds, with cluster-specific tuning.
- Visualize in Grafana alongside existing heartbeat dashboards.

---

## 2. Current State

### Heartbeat Schema (existing)

```sql
CREATE TABLE boss_heartbeats (
  boss_id String,
  cluster String,
  timestamp DateTime64(3) DEFAULT now(),
  docker_running UInt16,
  docker_total UInt16,
  disk_used_pct UInt8,
  mem_used_pct UInt8,
  load_1m Float32,
  agent_alive Bool DEFAULT true
) ENGINE = ReplacingMergeTree
ORDER BY (boss_id, timestamp);
```

### Current Collect Command

```bash
df / | tail -1 | awk '{print $5}' | tr -d '%'
```

### Limitations

- `disk_used_pct` is an integer (UInt8), losing precision at small percentages.
- No absolute byte values, so we can't compute meaningful growth rates:
  - 5% on Mac (~13 GiB) vs 5% on sim (~2 GiB) -- same percentage, vastly different absolute consumption.
  - Growth rate in "percentage points per day" is non-linear with respect to actual consumption.
- No inode tracking -- an inode exhaustion can cause failures even with free bytes.
- No filesystem info -- different mount points (e.g., overlay2, logs, data) have different growth patterns.

---

## 3. Design

### Approach

We will:

1. **Add a dedicated disk metrics table** in ClickHouse, separate from heartbeats. This keeps the heartbeat table lightweight and allows higher-frequency / more detailed disk sampling without bloating the heartbeat stream.
2. **Emit disk metrics from each boss** every 5 minutes (vs. 60s for heartbeats). Disk changes slowly; 5 min granularity is sufficient and reduces storage.
3. **Compute daily rollups** using a materialized view or scheduled aggregation, storing per-cluster daily growth rate, average usage, and projected exhaustion.
4. **Run prediction queries** on the daily rollup to compute exhaustion date using a simple linear model.
5. **Alert via the existing hook system** (cc-connect / feishu) when thresholds are breached.

### Data Collection Pipeline

```
Each boss (every 5 min)
    │  curl POST to CK
    ▼
ClickHouse: cluster_disk_metrics (raw)
    │
    ▼
Materialized View: cluster_disk_daily_rollup
    │
    ▼
Grafana: dashboards + alert queries
    │
    ▼
cc-connect or patrol: send feishu alert
```

### Metrics Per Collection Point

| Field | Type | Source | Example |
|-------|------|--------|---------|
| cluster | String | config (hostname) | `aliyun` |
| boss_id | String | hostname | `kyb-infra-boss` |
| timestamp | DateTime64(3) | now() | `2026-05-23T12:00:00.000Z` |
| mount_point | String | df output | `/` or `/var/lib/docker` |
| total_bytes | UInt64 | df --block-size=1 | 42949672960 |
| used_bytes | UInt64 | df --block-size=1 | 12884901888 |
| avail_bytes | UInt64 | df --block-size=1 | 30064771072 |
| used_pct | Float32 | used_bytes / total_bytes * 100 | 30.0 |
| inode_used_pct | Float32 | df -i | 12.5 |
| docker_overlay_bytes | Nullable(UInt64) | du -sb /var/lib/docker/overlay2 | 5368709120 |

---

## 4. ClickHouse Schema

### Raw Metrics Table

```sql
CREATE TABLE cluster_disk_metrics (
    cluster         LowCardinality(String),
    boss_id         String,
    timestamp       DateTime64(3),
    mount_point     LowCardinality(String) DEFAULT '/',
    total_bytes     UInt64,
    used_bytes      UInt64,
    avail_bytes     UInt64,
    used_pct        Float32,
    inode_used_pct  Float32,
    docker_overlay_bytes Nullable(UInt64)
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (cluster, timestamp, mount_point)
TTL timestamp + INTERVAL 180 DAY
```

**Design Notes:**

- **Partition by month** -- 3 nodes x 96 samples/day x 30 days = ~8640 rows/month. Even with docker_overlay_bytes, storage is tiny. Partitioning makes cleanup and backfill easy.
- **TTL 180 days** -- enough to see 6-month growth trends. Can be extended later if needed.
- **ORDER BY (cluster, timestamp, mount_point)** -- supports per-cluster time series queries and mount-point breakdown.
- **used_pct as Float32** -- preserves fractional percentages, unlike the UInt8 in heartbeats.

### Daily Rollup Materialized View

```sql
CREATE MATERIALIZED VIEW cluster_disk_daily_mv
ENGINE = SummingMergeTree
ORDER BY (cluster, date, mount_point)
POPULATE
AS
SELECT
    cluster,
    toDate(timestamp) AS date,
    mount_point,
    anyLast(total_bytes) AS total_bytes_end_of_day,
    argMax(used_bytes, timestamp) AS used_bytes_end_of_day,
    argMax(avail_bytes, timestamp) AS avail_bytes_end_of_day,
    avg(used_pct) AS used_pct_avg,
    max(used_pct) AS used_pct_max,
    min(used_pct) AS used_pct_min,
    avg(inode_used_pct) AS inode_used_pct_avg,
    argMax(docker_overlay_bytes, timestamp) AS docker_overlay_bytes_end_of_day,
    count() AS sample_count
FROM cluster_disk_metrics
GROUP BY cluster, date, mount_point;
```

### Predicted Exhaustion Table (Updated by Scheduled Query)

```sql
CREATE TABLE cluster_disk_exhaustion (
    cluster             LowCardinality(String),
    mount_point         LowCardinality(String) DEFAULT '/',
    computed_at         DateTime64(3) DEFAULT now(),
    total_bytes         UInt64,
    used_bytes          UInt64,
    avail_bytes         UInt64,
    used_pct            Float32,
    daily_growth_bytes  Float64,
    daily_growth_pct    Float64,
    days_until_full     Float64,
    exhaustion_date     Date,
    confidence          LowCardinality(String) DEFAULT 'low',
                               -- high: R^2 > 0.7, 14+ days of data
                               -- medium: R^2 > 0.4, 7+ days
                               -- low: insufficient data or weak trend
    warning             Bool DEFAULT false,
    critical            Bool DEFAULT false
) ENGINE = ReplacingMergeTree
ORDER BY (cluster, mount_point);
```

The exhaustion table is updated by a scheduled query (e.g., a cron script or cc-connect cron) that:

1. Reads the last 14-30 days of daily rollup data.
2. Fits a linear regression: `used_bytes ~ day_offset`.
3. Projects forward: `exhaustion_day = (total_bytes - intercept) / slope`.
4. Writes the result to `cluster_disk_exhaustion`.

---

## 5. Collection Script

### 5.1 The `collect-disk-metrics.sh` Script

Deployed to each infra-boss container at `/usr/local/bin/collect-disk-metrics.sh`:

```bash
#!/bin/bash
# collect-disk-metrics.sh -- Send disk metrics to central ClickHouse
# Runs every 5 minutes via cron or boss loop.

set -euo pipefail

CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"
BOSS_ID="${BOSS_ID:-$(hostname)}"
CLUSTER="${CLUSTER:-unknown}"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

# --- Main disk (df /) ---
eval $(df / --block-size=1 --output=size,used,avail,ipcent,target | tail -1 | awk '{
  printf "TOTAL_BYTES=%s\n", $1
  printf "USED_BYTES=%s\n", $2
  printf "AVAIL_BYTES=%s\n", $3
  printf "INODE_PCT=%s\n", $4
  printf "MOUNT=%s\n", $5
}')

USED_PCT=$(awk "BEGIN {printf \"%.1f\", $USED_BYTES * 100 / $TOTAL_BYTES}")

# --- Docker overlay size (best-effort) ---
DOCKER_OVERLAY="null"
if [ -d /var/lib/docker/overlay2 ]; then
  DOCKER_OVERLAY=$(du -sb /var/lib/docker/overlay2 2>/dev/null | cut -f1)
fi
# If the value is empty, set to null
[ -z "$DOCKER_OVERLAY" ] && DOCKER_OVERLAY="null"

# --- Also collect /var/lib/docker if it is a separate mount ---
# (For now we only collect the root mount. Multi-mount support is future work.)

# --- Push to ClickHouse ---
curl -s -X POST "$CK_HOST" \
  -H "Content-Type: text/plain" \
  --data-binary @- << PAYLOAD
INSERT INTO cluster_disk_metrics FORMAT JSONEachRow
{
  "cluster": "$CLUSTER",
  "boss_id": "$BOSS_ID",
  "timestamp": "$TIMESTAMP",
  "mount_point": "$MOUNT",
  "total_bytes": $TOTAL_BYTES,
  "used_bytes": $USED_BYTES,
  "avail_bytes": $AVAIL_BYTES,
  "used_pct": $USED_PCT,
  "inode_used_pct": $INODE_PCT,
  "docker_overlay_bytes": $DOCKER_OVERLAY
}
PAYLOAD
```

### 5.2 Deploy to Each Boss

**Mac/Orbstack (super-boss, local):**

```bash
# Install script
docker cp collect-disk-metrics.sh infra-boss:/usr/local/bin/
docker exec infra-boss chmod +x /usr/local/bin/collect-disk-metrics.sh

# Set cluster name (once)
docker exec infra-boss bash -c "echo 'export CLUSTER=mac-orbstack' >> /etc/environment"

# Add to cron (every 5 minutes)
docker exec infra-boss bash -c '
  echo "*/5 * * * * root /usr/local/bin/collect-disk-metrics.sh" > /etc/cron.d/disk-metrics
'
```

**Aliyun (sim) and Office (nuc8):**

```bash
# Copy script and set up via SSH
for host in sim nuc8; do
  scp collect-disk-metrics.sh dongqs@$host:/tmp/
  ssh dongqs@$host "
    docker cp /tmp/collect-disk-metrics.sh kyb-infra-boss:/usr/local/bin/
    docker exec kyb-infra-boss chmod +x /usr/local/bin/collect-disk-metrics.sh
  "
done

# Set cluster names
ssh sim 'docker exec kyb-infra-boss bash -c "echo export CLUSTER=aliyun >> /etc/environment"'
ssh nuc8 'docker exec kyb-infra-boss bash -c "echo export CLUSTER=office >> /etc/environment"'

# Add cron
for host in sim nuc8; do
  ssh dongqs@$host 'docker exec kyb-infra-boss bash -c "
    echo \"*/5 * * * * root /usr/local/bin/collect-disk-metrics.sh\" > /etc/cron.d/disk-metrics
  "'
done
```

### 5.3 Alternative: Extend the Heartbeat Loop

Instead of a separate cron job, the disk collection can be added to the existing heartbeat loop. This avoids introducing cron inside the boss container:

```bash
# Inside the heartbeat loop, add disk metrics inline:
while true; do
  # --- Existing heartbeat ---
  curl -s -X POST http://100.104.244.99:8123 \
    -d "INSERT INTO boss_heartbeats FORMAT JSONEachRow { ... }"

  # --- Extended: disk metrics every 5th iteration (5 min) ---
  if [ $((COUNTER % 5)) -eq 0 ]; then
    /usr/local/bin/collect-disk-metrics.sh
  fi
  ((COUNTER++))

  sleep 60
done
```

Either approach works. The separate cron is cleaner for isolation; the extended loop adds no new infrastructure.

---

## 6. Exhaustion Prediction

### 6.1 SQL Prediction Query

Run against `cluster_disk_daily_mv` to compute projected exhaustion:

```sql
WITH
    -- Window: last 30 days of data for each cluster
    recent AS (
        SELECT
            cluster,
            date,
            used_bytes_end_of_day AS used_bytes,
            toUnixTimestamp(date) / 86400 AS day_num  -- days since epoch
        FROM cluster_disk_daily_mv
        WHERE date >= today() - 30
          AND mount_point = '/'
    ),
    -- Linear regression coefficients per cluster
    regression AS (
        SELECT
            cluster,
            -- slope = (n*sum(xy) - sum(x)*sum(y)) / (n*sum(x^2) - sum(x)^2)
            (count() * sum(day_num * used_bytes) - sum(day_num) * sum(used_bytes))
            / (count() * sum(day_num * day_num) - sum(day_num) * sum(day_num))
                AS growth_per_day,
            -- intercept = (sum(y) - slope * sum(x)) / n
            (sum(used_bytes) - growth_per_day * sum(day_num)) / count() AS intercept,
            -- Current used bytes (latest data point)
            argMax(used_bytes, day_num) AS current_used,
            -- Total bytes (latest data point)
            argMax(total_bytes_end_of_day, day_num) AS total
        FROM recent
        GROUP BY cluster
    )
SELECT
    cluster,
    current_used AS used_bytes,
    total AS total_bytes,
    round(current_used * 100.0 / total, 1) AS used_pct,
    round(growth_per_day / 1024 / 1024 / 1024, 3) AS daily_growth_GB,
    round(growth_per_day * 100.0 / total, 3) AS daily_growth_pct,
    CASE
        WHEN growth_per_day <= 0 THEN NULL
        ELSE round((total - current_used) / growth_per_day, 1)
    END AS days_until_full,
    CASE
        WHEN growth_per_day <= 0 THEN CAST(NULL AS Date)
        ELSE toDate(today() + toInt64((total - current_used) / growth_per_day))
    END AS exhaustion_date,
    -- R-squared for confidence
    ...
FROM regression
```

The prediction is simple linear regression on `used_bytes_end_of_day` over the last 14-30 days. This is deliberately simple -- for our scale (3 clusters, predictable growth patterns), a linear model is sufficient. If growth is exponential (e.g., runaway logs), the linear model will still catch it early because the slope increases over time and the days_until_full will shrink rapidly, triggering alerts.

### 6.2 Prediction Script

A scheduled script (`predict-disk-exhaustion.sh`) runs every hour to update the `cluster_disk_exhaustion` table:

```bash
#!/bin/bash
# predict-disk-exhaustion.sh -- Update exhaustion predictions
# Runs every hour via cron on the super-boss (or any node that can reach CK).

CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"

curl -s -X POST "$CK_HOST" --data-binary "
INSERT INTO cluster_disk_exhaustion
WITH
    recent AS (
        SELECT
            cluster,
            date,
            anyLast(total_bytes) AS total_bytes,
            argMax(used_bytes, timestamp) AS used_bytes
        FROM cluster_disk_daily_mv
        WHERE date >= today() - 30
        GROUP BY cluster, date
    ),
    stats AS (
        SELECT
            cluster,
            count() AS n,
            sum(toUnixTimestamp(date)) AS sum_x,
            sum(used_bytes) AS sum_y,
            sum(toUnixTimestamp(date) * used_bytes) AS sum_xy,
            sum(toUnixTimestamp(date) * toUnixTimestamp(date)) AS sum_xx,
            sum(used_bytes * used_bytes) AS sum_yy,
            argMax(total_bytes, date) AS total_bytes_latest,
            argMax(used_bytes, date) AS used_bytes_latest
        FROM recent
        GROUP BY cluster
    ),
    linreg AS (
        SELECT
            cluster,
            total_bytes_latest,
            used_bytes_latest,
            (n * sum_xy - sum_x * sum_y) / (n * sum_xx - sum_x * sum_x) AS slope,
            (sum_y - slope * sum_x) / n AS intercept,
            -- R-squared
            (n * sum_xy - sum_x * sum_y) / sqrt(
                (n * sum_xx - sum_x * sum_x) * (n * sum_yy - sum_y * sum_y)
            ) AS r
        FROM stats
    )
SELECT
    cluster,
    '/' AS mount_point,
    now() AS computed_at,
    total_bytes_latest AS total_bytes,
    used_bytes_latest AS used_bytes,
    total_bytes_latest - used_bytes_latest AS avail_bytes,
    round(used_bytes_latest * 100.0 / total_bytes_latest, 1) AS used_pct,
    slope AS daily_growth_bytes,
    round(slope * 100.0 / total_bytes_latest, 4) AS daily_growth_pct,
    CASE
        WHEN slope <= 0 THEN -1
        ELSE (total_bytes_latest - used_bytes_latest) / slope
    END AS days_until_full,
    CASE
        WHEN slope <= 0 THEN toDate('2099-12-31')
        ELSE toDate(today() + toInt64((total_bytes_latest - used_bytes_latest) / slope))
    END AS exhaustion_date,
    CASE
        WHEN n < 7 THEN 'low'
        WHEN r * r < 0.4 THEN 'low'
        WHEN r * r < 0.7 THEN 'medium'
        ELSE 'high'
    END AS confidence,
    days_until_full >= 0 AND days_until_full <= 30 AS warning,
    days_until_full >= 0 AND days_until_full <= 7 AS critical
FROM linreg
"
```

### 6.3 When Prediction Is Unreliable

| Situation | What happens | How to handle |
|-----------|-------------|---------------|
| <7 days of data | confidence = "low", no alert | Wait for more data points |
| Negative growth (disk shrinking) | days_until_full = -1, no alert | Normal after cleanup |
| Zero growth | days_until_full = -1, no alert | Stable state |
| R^2 < 0.4 | confidence = "low", alert suppressed | Unstable trend; investigate cause |
| First 48h after cleanup | Sudden drop in used_bytes, slope temporarily negative | Normal; alert logic ignores negative slopes |
| Exponential growth (runaway logs) | Linear model underestimates, but days_until_full shrinks quickly | Catch on next prediction cycle; critical alert will fire |

---

## 7. Alert Thresholds

### 7.1 Cluster-Specific Thresholds

Each cluster has different disk sizes and growth profiles, so thresholds must be absolute (bytes remaining), not percentage-based:

| Cluster | Disk Size | Warning (bytes) | Warning (days) | Critical (bytes) | Critical (days) | Typical daily growth |
|---------|-----------|----------------|----------------|------------------|----------------|----------------------|
| Mac/Orbstack | ~260 GiB | < 20 GiB | < 30 days | < 5 GiB | < 7 days | ~200 MiB - 1 GiB |
| Aliyun (sim) | ~40 GiB | < 5 GiB | < 14 days | < 2 GiB | < 3 days | ~50 - 200 MiB |
| Office (nuc8) | ~256 GiB | < 20 GiB | < 30 days | < 5 GiB | < 7 days | ~100 - 500 MiB |

### 7.2 Alert Conditions

Alerts fire when **either** the byte threshold or the days-until-full threshold is breached (whichever is more conservative):

```
For each cluster:
  IF avail_bytes < warning_bytes OR days_until_full < warning_days
    → WARNING alert (feishu message to ops channel)

  IF avail_bytes < critical_bytes OR days_until_full < critical_days
    → CRITICAL alert (feishu message to ops channel + @user)

  IF used_pct > 95
    → CRITICAL alert regardless of prediction (hard cap)
```

### 7.3 Alert Message Format

```
🔴 [CRITICAL] Disk exhaustion imminent on aliyun (sim)
  - Mount: /
  - Used: 36.2 GiB / 40.0 GiB (90.5%)
  - Available: 3.8 GiB
  - Daily growth: ~200 MiB/day (0.5%/day)
  - Predicted exhaustion: 2026-06-01 (in 9 days)
  - Confidence: high (R²=0.89, 28 data points)
  - Suggestion: Run `docker system prune -a` or investigate /var/lib/docker/overlay2
```

### 7.4 Alert Suppression

- After a manual cleanup (e.g., `docker system prune`), alerts should auto-reset when the prediction recalculates (hourly). No manual dismiss needed.
- If `confidence = "low"`, suppress alerts. Insufficient data or weak trend means the prediction is unreliable.
- If `growth_per_day <= 0`, suppress alerts. Disk is stable or shrinking.

### 7.5 Integration with Existing Alerting

The disk exhaustion table is queried by the patrol system (5-min patrol guide) or by cc-connect cron:

```sql
-- Query used by patrol/alerter
SELECT cluster, used_pct, daily_growth_pct, days_until_full, exhaustion_date, confidence
FROM cluster_disk_exhaustion
WHERE critical = 1 OR warning = 1
ORDER BY critical DESC, days_until_full ASC
```

The patrol script already runs every 5 minutes. An additional check can be added:

```bash
# In the patrol loop, after healthcheck:
CRITICAL_DISK=$(curl -s "http://100.104.244.99:8123?query=SELECT%20cluster%2Cdays_until_full%20FROM%20cluster_disk_exhaustion%20WHERE%20critical%3D1")
if [ -n "$CRITICAL_DISK" ]; then
  kyb notify urgent "Critical disk alert: $CRITICAL_DISK"
fi
```

---

## 8. Grafana Dashboard

### Panel 1: Current Disk Usage by Cluster (Gauge / Stat)

- Query: `SELECT cluster, used_pct, total_bytes, used_bytes, avail_bytes FROM cluster_disk_exhaustion`
- Display: One stat per cluster, showing used_pct as a gauge with min/max thresholds.
- Thresholds: Green < 70%, Yellow 70-85%, Red > 85%.

### Panel 2: Disk Usage Over Time (Time Series)

- Query: `SELECT timestamp, cluster, used_bytes FROM cluster_disk_metrics WHERE $__timeFilter ORDER BY timestamp`
- Display: Multi-line time series, one line per cluster, Y-axis in GiB.
- Overlay: Add a trend line (dashed) showing the linear projection.

### Panel 3: Daily Growth Rate (Bar Chart)

- Query: `SELECT date, cluster, daily_growth_bytes FROM cluster_disk_daily_mv WHERE $__timeFilter ORDER BY date`
- Display: Grouped bar chart, one bar per cluster per day, Y-axis in MiB/GiB.
- Purpose: Spot unusual growth spikes (e.g., a day where growth jumped 10x).

### Panel 4: Exhaustion Countdown (Table)

- Query:
  ```sql
  SELECT
    cluster,
    used_pct,
    daily_growth_pct,
    days_until_full,
    exhaustion_date,
    confidence,
    CASE WHEN critical THEN 'CRITICAL' WHEN warning THEN 'WARNING' ELSE 'OK' END AS status
  FROM cluster_disk_exhaustion
  ```
- Display: Table with conditional formatting (red for critical, yellow for warning).
- Sort: By days_until_full ASC (shortest first).

### Panel 5: Docker Overlay Size (Time Series, Optional)

- Query: `SELECT timestamp, cluster, docker_overlay_bytes FROM cluster_disk_metrics WHERE docker_overlay_bytes IS NOT NULL AND $__timeFilter`
- Display: Line chart in GiB.
- Purpose: Identify if Docker images/containers are the primary growth driver.

---

## 9. Integration with Existing Systems

### 9.1 Patrol System

The [5-min patrol guide](5min-patrol-guide.md) already checks `df -h`. The disk monitoring system replaces the manual disk check with automated:

- **Predictive alerts** catch disk issues before they become urgent.
- **Historical trends** let you see growth patterns over days/weeks.
- **Cluster-specific thresholds** mean sim's tiny 40 GiB disk gets appropriate attention.

The patrol script should be updated to query `cluster_disk_exhaustion` instead of running `df -h` directly:

```bash
# Old: manual df -h check
# df -h / | ...

# New: query CK for latest prediction
curl -s "http://100.104.244.99:8123?query=SELECT%20cluster%2Cused_pct%2Cdays_until_full%2Cexhaustion_date%20FROM%20cluster_disk_exhaustion%20ORDER%20BY%20cluster"
```

### 9.2 Heartbeat Enhancement

The existing heartbeat `boss_heartbeats.disk_used_pct` continues to work as a quick health indicator. The new disk metrics table adds detail without breaking existing queries.

### 9.3 cc-connect Cron Integration

Following the pattern from [issue automation](designs/issue-automation.md) (recommended: cc-connect cron), disk alerts can be sent as feishu messages:

```bash
# cc-connect cron entry for hourly disk check
cc-connect cron add --schedule "0 * * * *" --exec "
  CRITICAL=\$(curl -s 'http://100.104.244.99:8123?query=SELECT%20cluster%2Cexhaustion_date%20FROM%20cluster_disk_exhaustion%20WHERE%20critical%3D1')
  if [ -n \"\$CRITICAL\" ]; then
    cc-connect send --target chat_id=oc_xxxx --msg \"🔴 [CRITICAL] Disk alert: \$CRITICAL\"
  fi
  WARNING=\$(curl -s 'http://100.104.244.99:8123?query=SELECT%20cluster%2Cexhaustion_date%20FROM%20cluster_disk_exhaustion%20WHERE%20warning%3D1%20AND%20critical%3D0')
  if [ -n \"\$WARNING\" ]; then
    cc-connect send --target chat_id=oc_xxxx --msg \"🟡 [WARNING] Disk nearing full: \$WARNING\"
  fi
"
```

### 9.4 Retention & Cleanup

| Table | Retention | Cleanup mechanism |
|-------|-----------|-------------------|
| `cluster_disk_metrics` | 180 days | TTL on MergeTree |
| `cluster_disk_daily_mv` | 365 days | Managed by TTL on source table + periodic cleanup |
| `cluster_disk_exhaustion` | 1 row per cluster (latest) | ReplacingMergeTree replaces on ORDER BY |

---

## 10. Rollout Plan

### Phase 1: Schema + Collection (Day 1)

1. Create ClickHouse tables on central CK (Mac/Orbstack).
2. Deploy `collect-disk-metrics.sh` to each boss container.
3. Verify data ingests after 5 minutes.

### Phase 2: Prediction + Dashboard (Day 1-2)

1. Deploy `predict-disk-exhaustion.sh` on super-boss (runs hourly).
2. Build Grafana dashboard panels.
3. Verify predictions match manual analysis.

### Phase 3: Alerting (Day 2)

1. Add disk check to patrol script.
2. Configure cc-connect cron for feishu alerts.
3. Set initial thresholds, observe for 24h.

### Phase 4: Tuning (Day 3-7)

1. Adjust threshold values based on observed growth patterns.
2. Tune confidence levels if false positives occur.
3. Add cluster-specific overrides if needed.

---

> **Summary:** Track `disk_used_bytes` every 5 minutes per cluster, compute daily rollups, fit a linear regression to predict exhaustion date, and alert via feishu when disk is projected to fill within 30 days (warning) or 7 days (critical). Aliyun/sim with its 40 GiB disk gets tighter thresholds (14/3 days). The system integrates with the existing heartbeat, patrol, and cc-connect infrastructure.

> /人◕ ‿‿ ◕人＼
