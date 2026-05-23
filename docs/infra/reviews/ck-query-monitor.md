---
decision: 稍后做
---

# CK Query Performance Monitoring

**Status:** Draft design
**Date:** 2026-05-24
**CK Version:** 24.2-alpine (client 25.1.3)
**Grafana:** 11.x with grafana-clickhouse-datasource

---

## Current State

| Item | Detail |
|------|--------|
| system.query_log | 174K rows, ~22MB, partitioned by month, **no TTL** |
| Grafana CK datasource | Configured (`http://host.orb.internal:8123`) |
| Custom dashboards | None provisioned |
| Dashboard provisioning | Not configured (`/etc/grafana/provisioning/dashboards/` exists but empty) |
| Tables without partition key | ~80% of user tables have no partition key (all `min_date = 1970-01-01`) |
| Largest table | `topo.buildings` (~4.1 GB, 45M rows, no partition key) |

---

## 1. Slow Query Log Analysis

### 1.1 Enable Retention TTL on system.query_log

The query_log currently has no TTL — data accumulates indefinitely at ~22MB/month. Even at this volume it is not critical, but standard practice is a 90-day retention.

```sql
ALTER TABLE system.query_log MODIFY TTL event_date + INTERVAL 90 DAY DELETE;
```

Alternatively, set `database_system_database_query_log_ttl` in `config.d/query_log.xml`:

```xml
<clickhouse>
  <query_log>
    <database>system</database>
    <table>query_log</table>
    <partition_by>toYYYYMM(event_date)</partition_by>
    <ttl>event_date + INTERVAL 90 DAY</ttl>
    <flush_interval_milliseconds>7500</flush_interval_milliseconds>
  </query_log>
</clickhouse>
```

### 1.2 Key Queries for Monitoring

**P50/P90/P99 latency by database (last 24h):**
```sql
SELECT
    current_database,
    count()                               AS query_count,
    avg(query_duration_ms)                AS avg_ms,
    quantile(0.50)(query_duration_ms)     AS p50_ms,
    quantile(0.90)(query_duration_ms)     AS p90_ms,
    quantile(0.99)(query_duration_ms)     AS p99_ms,
    max(query_duration_ms)                AS max_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= yesterday()
GROUP BY current_database
ORDER BY avg_ms DESC
```

**Slowest queries in last 24h (>1s):**
```sql
SELECT
    event_time,
    query_duration_ms,
    memory_usage,
    read_rows,
    result_rows,
    query_kind,
    left(query, 120)                      AS query_preview,
    databases,
    tables
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= yesterday()
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 50
```

**Memory hogs (>500MB):**
```sql
SELECT
    event_time,
    query_duration_ms,
    memory_usage,
    read_rows,
    result_rows,
    left(query, 120)                      AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= yesterday()
  AND memory_usage > 500000000
ORDER BY memory_usage DESC
LIMIT 20
```

**Inefficient scans (read_rows >> result_rows):**
```sql
SELECT
    event_time,
    query_duration_ms,
    read_rows,
    result_rows,
    round(read_rows / greatest(result_rows, 1)) AS rows_efficiency_ratio,
    memory_usage,
    left(query, 120)                      AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= yesterday()
  AND read_rows > 100000
  AND read_rows > 10 * result_rows
ORDER BY read_rows DESC
LIMIT 30
```

**Error rate by exception_code:**
```sql
SELECT
    exception_code,
    count()                               AS error_count,
    countIf(type = 'ExceptionWhileProcessing') AS while_processing,
    countIf(type = 'ExceptionBeforeStart')     AS before_start
FROM system.query_log
WHERE event_date >= yesterday()
  AND exception_code != 0
GROUP BY exception_code
ORDER BY error_count DESC
```

### 1.3 Normalized Query Fingerprinting

Use `normalized_query_hash` to group identical query shapes:

```sql
SELECT
    normalized_query_hash,
    count()                               AS run_count,
    avg(query_duration_ms)                AS avg_ms,
    quantile(0.95)(query_duration_ms)     AS p95_ms,
    sum(read_rows)                        AS total_rows_read,
    left(any(query), 200)                  AS sample_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= yesterday()
GROUP BY normalized_query_hash
HAVING run_count > 5
ORDER BY avg_ms DESC
LIMIT 30
```

---

## 2. Table Size Monitoring

### 2.1 Daily Size Snapshot

Create a monitoring table to log daily size snapshots. This enables growth trend analysis.

```sql
CREATE TABLE monitor.table_sizes_daily
(
    event_date     Date,
    database       String,
    table          String,
    engine         String,
    total_rows     UInt64,
    total_bytes    UInt64,
    partition_key  String,
    sorting_key    String
)
ENGINE = ReplacingMergeTree
ORDER BY (event_date, database, table)
```

Insert via cron or cc-connect cron (recommended for zero-infra):

```sql
INSERT INTO monitor.table_sizes_daily
SELECT
    today() AS event_date,
    database,
    name AS table,
    engine,
    total_rows,
    total_bytes,
    partition_key,
    sorting_key
FROM system.tables
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')
```

### 2.2 Top Tables by Size

```sql
SELECT
    database,
    name                                        AS table,
    engine,
    formatReadableSize(total_bytes)             AS disk_size,
    total_rows,
    partition_key,
    sorting_key
FROM system.tables
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')
ORDER BY total_bytes DESC
```

### 2.3 Growth Trend

```sql
SELECT
    database,
    table,
    total_rows - lagInFrame(total_rows) OVER (PARTITION BY database, table ORDER BY event_date) AS daily_row_delta,
    total_bytes - lagInFrame(total_bytes) OVER (PARTITION BY database, table ORDER BY event_date) AS daily_byte_delta
FROM monitor.table_sizes_daily
WHERE event_date >= today() - 14
ORDER BY database, table, event_date
```

---

## 3. Partition Health

### 3.1 Tables Without Partition Keys

This is the single biggest structural issue: ~80% of tables have no partition key. Tables without partitions cannot be pruned, meaning every SELECT must scan all data.

```sql
SELECT
    database,
    name                AS table,
    engine,
    formatReadableSize(total_bytes) AS size,
    total_rows,
    partition_key,
    sorting_key
FROM system.tables
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')
  AND engine NOT IN ('View', 'Distributed', 'Dictionary', 'MaterializedView')
  AND partition_key = ''
ORDER BY total_bytes DESC
```

**Recommended partition keys (by data type):**
- **Event/time-series data** (`daily.*`, `kafka.*`, `merged.*`, `stated.*`): `toYYYYMM(date)` or `toYYYYMMDD(event_date)`
- **Batch-loaded tables** (`topo.buildings`): `toYYYYMM(load_date)` if incremental, or leave unpartitioned if static (<5GB)
- **Small lookup tables** (<1GB, rarely updated): leave unpartitioned

### 3.2 Partition Count Warning

Too many small partitions cause slow merges and query degradation.

```sql
SELECT
    database,
    table,
    count()                                  AS partition_count,
    sum(rows)                                AS total_rows,
    formatReadableSize(sum(bytes_on_disk))   AS total_size,
    min(min_date)                            AS oldest_date,
    max(max_date)                            AS newest_date
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system', 'INFORMATION_SCHEMA')
GROUP BY database, table
ORDER BY partition_count DESC
```

**Alert threshold:** >50 partitions per table, or >10 partitions created in the last hour.

### 3.3 Inactive / Stale Parts

```sql
SELECT
    database,
    table,
    partition,
    count() AS part_count,
    sum(rows) AS total_rows
FROM system.parts
WHERE active = 0
  AND database NOT IN ('system', 'INFORMATION_SCHEMA')
GROUP BY database, table, partition
ORDER BY part_count DESC
LIMIT 30
```

A high number of inactive parts indicates merge lag or a stuck merge queue.

### 3.4 Merge Queue Depth

```sql
SELECT
    database,
    table,
    count()                                 AS pending_merges,
    sum(rows_to_merge)                       AS rows_to_merge,
    max(partition_id)                        AS latest_partition
FROM system.merges
WHERE database NOT IN ('system')
GROUP BY database, table
ORDER BY pending_merges DESC
```

---

## 4. System-Level Metrics

### 4.1 Current Merges

```sql
SELECT
    database,
    table,
    elapsed,
    progress,
    round(elapsed * (1 - progress) / progress) AS estimated_remaining_seconds,
    written_rows,
    total_size_bytes_compressed,
    total_size_bytes_uncompressed,
    memory_usage,
    merge_type,
    merge_algorithm
FROM system.merges
WHERE database NOT IN ('system')
ORDER BY elapsed DESC
```

### 4.2 Disk Space

```sql
SELECT
    name,
    path,
    formatReadableSize(free_space)           AS free,
    formatReadableSize(total_space)           AS total,
    round(free_space / total_space * 100, 1)  AS free_pct
FROM system.disks
```

### 4.3 Replication Lag (if multi-replica)

```sql
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue
FROM system.replicas
```

---

## 5. Grafana Dashboard

### 5.1 Provisioning Setup

Create `/etc/grafana/provisioning/dashboards/dashboards.yaml`:

```yaml
apiVersion: 1

providers:
  - name: ClickHouse
    type: file
    disableDeletion: true
    editable: true
    updateIntervalSeconds: 60
    options:
      path: /var/lib/grafana/dashboards
```

Dashboard JSON files go into `/var/lib/grafana/dashboards/`.

### 5.2 Suggested Dashboard Layout

Dashboard name: **ClickHouse Query Monitor**

Refresh: 30s default, auto-refresh supported for all panels.

#### Row 1: Overview (stat panels + quick stats)

| Panel | Type | Query / Description |
|-------|------|-------------------|
| Queries / sec | Stat (sparkline) | `SELECT count() / 86400 FROM system.query_log WHERE event_date = today() AND type='QueryFinish'` |
| Active Queries | Stat | `SELECT count() FROM system.processes` |
| Pending Merges | Stat | `SELECT count() FROM system.merges` |
| Disk Usage | Stat | `SELECT round(100 - free_space/total_space*100, 1) FROM system.disks LIMIT 1` |
| Database Count | Stat | `SELECT count() FROM system.databases WHERE name NOT IN ('system','INFORMATION_SCHEMA')` |

#### Row 2: Query Latency

| Panel | Type | Query |
|-------|------|-------|
| P50/P90/P99 by hour | Time series | `SELECT toStartOfHour(event_time) AS t, quantile(0.50)(query_duration_ms) AS p50, quantile(0.90)(query_duration_ms) AS p90, quantile(0.99)(query_duration_ms) AS p99 FROM system.query_log WHERE type='QueryFinish' AND event_date >= today()-7 GROUP BY t ORDER BY t` |
| P50/P90/P99 by database | Bar gauge | Same query grouped by `current_database` |
| Latency Heatmap | Heatmap | `SELECT event_time, query_duration_ms FROM system.query_log WHERE type='QueryFinish' AND event_date >= today()-1` |

#### Row 3: Throughput & Resource Usage

| Panel | Type | Query |
|-------|------|-------|
| Queries per minute | Time series | `SELECT toStartOfMinute(event_time) AS t, countIf(type='QueryFinish') AS finished, countIf(type='QueryStart') AS started FROM system.query_log WHERE event_date = today() GROUP BY t ORDER BY t` |
| Memory Usage (top 10) | Table | `SELECT event_time, query_duration_ms, formatReadableSize(memory_usage) AS mem, left(query, 80) AS q FROM system.query_log WHERE type='QueryFinish' AND event_date >= today() ORDER BY memory_usage DESC LIMIT 10` |
| Rows Read vs Returned | Time series | `SELECT toStartOfHour(event_time) AS t, sum(read_rows) AS rows_read, sum(result_rows) AS rows_returned FROM system.query_log WHERE type='QueryFinish' AND event_date >= today()-7 GROUP BY t ORDER BY t` |

#### Row 4: Slow Queries

| Panel | Type | Query |
|-------|------|-------|
| Slow Queries (>1s) | Table | As in §1.2 "Slowest queries" |
| Top Slow Users | Bar gauge | `SELECT user, count() AS cnt, avg(query_duration_ms) AS avg_ms, max(query_duration_ms) AS max_ms FROM system.query_log WHERE type='QueryFinish' AND event_date >= today()-1 AND query_duration_ms > 1000 GROUP BY user ORDER BY cnt DESC LIMIT 10` |
| Error Queries | Table | `SELECT event_time, exception_code, exception, left(query, 100) AS q FROM system.query_log WHERE event_date >= today() AND exception_code != 0 ORDER BY event_time DESC LIMIT 20` |

#### Row 5: Table & Partition Health

| Panel | Type | Query |
|-------|------|-------|
| Top Tables by Size | Table | As in §2.2 |
| Tables Without Partition Key | Table | As in §3.1 |
| Partition Count | Bar gauge | As in §3.2 |
| Merge Queue Depth | Time series or Stat | As in §3.4 |
| Inactive Parts | Table | As in §3.3 |

### 5.3 Dashboard Variables

Define these at the dashboard level for reusable filtering:

| Variable | Type | Query |
|----------|------|-------|
| `$database` | Query | `SELECT DISTINCT database FROM system.tables WHERE database NOT IN ('system','INFORMATION_SCHEMA')` |
| `$table` | Query | `SELECT DISTINCT name FROM system.tables WHERE database IN ($database) AND database NOT IN ('system','INFORMATION_SCHEMA')` |
| `$time_range` | Constant | `7` (days) |
| `$threshold` | Constant | `1000` (ms, for slow query threshold) |

---

## 6. Alerts

### 6.1 Low-Frequency Alerts (cc-connect cron / patrol)

These run via the existing 5-minute patrol mechanism (`docs/5min-patrol-guide.md`) or cc-connect cron schedule:

| Alert | Query | Threshold | Action |
|-------|-------|-----------|--------|
| P99 latency spike | P99 > 10s in last 5 min | >10s sustained for 2 consecutive patrols | Investigate running merges + slow queries |
| Table growth anomaly | daily row count delta > 2x previous day | >2x on any table >100MB | Check ingestion pipeline |
| Merge queue stuck | `pending_merges > 5` for >30 min | >5 merges pending for 30+ min | Check PartLog, may need manual OPTIMIZE |
| Disk >80% | `free_space / total_space < 0.2` | <20% free | Free disk or expand volume |
| Many failed queries | error rate >10% in last 5 min | >10% of queries failing | Check exception codes |

### 6.2 Grafana Alert Rules

Configure via Grafana Alerting UI (once dashboard is deployed):

1. **CK - High P99 Latency** — P99(query_duration_ms) > 10_000 over 5m → Warning
2. **CK - Disk Space** — disk free < 20% → Critical
3. **CK - Merge Backlog** — count(system.merges) > 10 → Warning
4. **CK - Query Error Rate** — error_count / total_count > 0.1 → Warning
5. **CK - No Partition Key** — tables_without_partition_key > 0 → Info (for migration tracking)

---

## 7. Implementation Roadmap

| Phase | Tasks | Owner |
|-------|-------|-------|
| **P0** | Configure query_log TTL (90d) | infra |
| **P0** | Create `monitor.table_sizes_daily` + cron | infra |
| **P0** | Provision Grafana dashboard JSON | infra |
| **P1** | Add partition keys to unpartitioned tables | data team |
| **P1** | Configure Grafana alert rules | infra |
| **P2** | Set up patrol alerts for merge lag/disk | infra |
| **P2** | Add query_log to S3/GCS cold storage (if >90d retention needed) | infra |

---

## Appendix: CK System Tables Used

| Table | Purpose | Size (current) |
|-------|---------|----------------|
| `system.query_log` | All query executions | ~22MB (174K rows) |
| `system.tables` | Table metadata, sizes | in-memory |
| `system.parts` | Data part / partition info | in-memory |
| `system.merges` | Active merge operations | in-memory |
| `system.processes` | Currently running queries | in-memory |
| `system.disks` | Disk space | in-memory |
| `system.replicas` | Replication lag (if applicable) | in-memory |
| `system.asynchronous_metrics` | OS-level metrics | in-memory |
| `system.metric_log` | CK internal metrics | ~1MB |
