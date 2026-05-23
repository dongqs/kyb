---
decision: 稍后做
---

# Review: PostgreSQL Replication Lag Monitoring

**Date:** 2026-05-23
**Status:** Design proposal
**Prerequisite reading:** `docs/infra/observability-design.md` (existing monitoring stack),
`docs/infra/5min-patrol-guide.md` (patrol integration).

---

## 1. Problem

PostgreSQL streaming replication is asynchronous by default. The following failure modes
are invisible without dedicated monitoring:

| Failure Mode | Detection | Consequence |
|---|---|---|
| Standby falls behind due to WAL replay stall | Lag metric crossing threshold | Stale reads on standby, data loss on failover |
| Replication slot becomes inactive / lost | Slot state check | WAL accumulation on primary -> disk full |
| WAL accumulation from idle slots | WAL size + slot stats | Primary disk full, PG crash |
| Conflicts on standby (vacuum vs. queries) | Conflict count + rate | Query cancellation, application errors |
| Replication connection drops | Client state check | Gap in WAL streaming, catch-up delay |

Without monitoring these, a primary disk-full event or silent standby divergence
is discovered only when it causes an outage.

---

## 2. Metrics to Collect

All queries run on the **primary** unless noted.

### 2.1 Replication Lag (Time)

```sql
-- On standby only. Returns time since last WAL replay.
-- Primary has no "receive" lag — it's the source.
SELECT
  now() - pg_last_xact_replay_timestamp() AS replay_lag_interval;
```

Alternatively, on the **primary**, for each standby:

```sql
SELECT
  client_addr,
  application_name,
  state,
  -- pg_wal_lsn_diff converts LSN positions to bytes.
  -- Divide by 16 for approximate MB.
  pg_wal_lsn_diff(pg_current_wal_lsn(), write_lag)  AS write_lag_bytes,
  pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lag)   AS flush_lag_bytes,
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lag)  AS replay_lag_bytes,
  -- Convert bytes to human-readable seconds using pg_stat_replication.write_lag
  -- (this requires wal_level >= replica)
  write_lag,
  flush_lag,
  replay_lag
FROM pg_stat_replication;
```

`pg_stat_replication.write_lag`, `flush_lag`, `replay_lag` are `interval` types
reported by the standby via the hot standby feedback / walreceiver protocol. They
are the most authoritative lag signal.

**Key thresholds:**
| Level | Replay Lag | Action |
|---|---|---|
| INFO | < 10s | Normal |
| WARN | 10s - 60s | Investigate: is standby CPU-bound on replay? |
| CRIT | > 60s | Alert: likely WAL replay stall or network issue |

### 2.2 Replication Slot State

Replication slots **must** be monitored because an inactive slot causes WAL to
accumulate on the primary indefinitely — PG will not remove WAL segments needed
by any slot, even if the standby is disconnected.

```sql
SELECT
  slot_name,
  slot_type,
  active,
  coalesce(wal_status, 'unknown') AS wal_status,
  pg_size_pretty(pg_wal_lsn_diff(
    pg_current_wal_lsn(),
    coalesce(restart_lsn, pg_current_wal_lsn())
  )::text::bigint) AS retained_wal_size_pretty,
  pg_wal_lsn_diff(
    pg_current_wal_lsn(),
    coalesce(restart_lsn, pg_current_wal_lsn())
  ) AS retained_wal_bytes,
  active_pid,
  xmin,
  catalog_xmin
FROM pg_replication_slots;
```

`wal_status` can be:
- `reserved` — normal, slot has WAL retained
- `extended` — slot behind but WAL still available
- `unreserved` — WAL may have been removed (slot is lost, standby can't catch up)
- `lost` — slot's WAL has been removed. This standby **must be rebuilt**.

**Alert:**
- `wal_status IN ('unreserved', 'lost')` → P0 alert, manual rebuild required
- `active = false AND wal_status = 'reserved'` for > 1h → P2, orphaned slot consuming disk
- `retained_wal_bytes > 10GB` → P2, investigate why slot is holding so much WAL

### 2.3 WAL Size (Primary)

Total WAL on disk, across `pg_wal`:

```sql
SELECT
  pg_size_pretty(sum(size)) AS total_wal_size,
  sum(size) AS total_wal_bytes
FROM pg_ls_waldir();
```

This should be relatively stable in steady state (checkpoint + WAL recycling keep it bounded).
A growing trend indicates:
- WAL is being generated faster than checkpoints can recycle it
- A replication slot is holding back WAL removal (see §2.2)
- `wal_keep_size` is set too high for the workload

**Threshold:** Total WAL > 10% of disk partition containing `pg_wal` → WARN.
> 20% → CRIT. (Adjust based on actual partition sizing.)

### 2.4 Replication Conflicts (Standby)

Run on the **standby** where application reads happen:

```sql
SELECT
  datname,
  confl_tablespace,
  confl_lock,
  confl_snapshot,
  confl_bufferpin,
  confl_deadlock
FROM pg_stat_database_conflicts;
```

Conflict counters are cumulative since last reset. Track the **rate of change**:

```sql
-- Run twice with T-second interval, then compute delta.
-- Pseudo: SELECT (c2.confl_snapshot - c1.confl_snapshot) / T AS snapshot_conflicts_per_sec
```

**Causes and mitigations:**
| Conflict Type | Common Cause | Mitigation |
|---|---|---|
| `confl_snapshot` | Primary VACUUM removes rows that a standby query is still reading | Set `hot_standby_feedback = on` |
| `confl_lock` | Primary DDL conflicts with standby queries | Align maintenance windows |
| `confl_tablespace` | Tablespace drop on primary | Rare, check application patterns |
| `confl_bufferpin` | Very rare, usually a PG bug | Check PG version |

**Threshold:** `confl_snapshot` rate > 1/sec sustained over 5 min → WARN.
Rate > 10/sec → CRIT (application queries are being cancelled at high rate).

### 2.5 Standby State (Primary View)

```sql
SELECT
  application_name,
  client_addr,
  state,
  sync_state,
  -- How long since this standby last sent us anything
  now() - coalesce(write_lag, '0'::interval) AS last_contact_age,
  -- Total WAL bytes this standby has streamed
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lag) AS bytes_behind
FROM pg_stat_replication
WHERE state IS NOT NULL;
```

`state` values to watch:
- `streaming` — normal
- `catchup` — standby is catching up (expected after reconnection)
- `backup` — standby is being used for pg_basebackup (temporary)
- `startup` — walreceiver connecting
- `stopped` — disconnected (alert immediately if sync standby)

**Alert:** Any non-streaming state persisting > 30s for a sync standby.
Async standby in `catchup` > 5 min → WARN.

---

## 3. Collection Architecture

### 3.1 Prometheus + postgres_exporter (Recommended)

Deploy `prometheuscommunity/postgres_exporter` alongside each PG instance.

```yaml
# docker-compose snippet for postgres_exporter
services:
  postgres_exporter:
    image: quay.io/prometheuscommunity/postgres-exporter:v0.15.0
    environment:
      DATA_SOURCE_NAME: "postgresql://postgres:postgres@pg-primary:5432/postgres?sslmode=disable"
      PG_EXPORTER_AUTO_DISCOVER_DATABASES: "true"
    ports:
      - "9187:9187"
    restart: unless-stopped
```

Built-in metrics (no custom queries needed for the basics):
| Metric | Source |
|---|---|
| `pg_replication_lag` | `pg_stat_replication.write_lag` |
| `pg_stat_replication` | `pg_stat_replication` (various columns) |
| `pg_replication_slots` | `pg_replication_slots` |
| `pg_wal_size_bytes` | WAL directory size (via collector) |

Custom queries are needed for:
- Replication conflict rates (`pg_stat_database_conflicts` — not in default collector)
- Per-slot retained WAL bytes (derived from LSNs)
- WAL file count and age distribution

Example custom query config (`queries.yaml`):

```yaml
pg_replication_conflicts:
  query: >-
    SELECT datname, confl_tablespace, confl_lock, confl_snapshot,
           confl_bufferpin, confl_deadlock
    FROM pg_stat_database_conflicts
    WHERE datname NOT IN ('template0', 'template1')
  metrics:
    - datname:
        usage: LABEL
    - confl_tablespace:
        usage: COUNTER
    - confl_lock:
        usage: COUNTER
    - confl_snapshot:
        usage: COUNTER
    - confl_bufferpin:
        usage: COUNTER
    - confl_deadlock:
        usage: COUNTER

pg_replication_slot_bytes:
  query: >-
    SELECT slot_name, slot_type, active,
           pg_wal_lsn_diff(pg_current_wal_lsn(),
             coalesce(restart_lsn, pg_current_wal_lsn())) AS retained_bytes
    FROM pg_replication_slots
  metrics:
    - slot_name:
        usage: LABEL
    - slot_type:
        usage: LABEL
    - active:
        usage: LABEL
    - retained_bytes:
        usage: GAUGE
```

### 3.2 Grafana Dashboard

Recommended dashboard panels:

| Panel | Metric | Query | Visual |
|---|---|---|---|
| Replay Lag (all standbys) | `pg_replication_lag{metric="replay_lag_seconds"}` | Time series, per standby | Line chart |
| Lag Heatmap | `pg_replication_lag{metric="write_lag_seconds"}` | Time series | Heatmap |
| Slot WAL Retention | `pg_replication_slot_retained_bytes` | Per slot | Stacked bar |
| Total WAL Size | `pg_wal_size_bytes` | Single stat + trend | Area chart |
| Conflict Rate | `rate(pg_replication_conflicts_total[5m])` | Per DB | Line chart |
| Standby State | `pg_stat_replication{state="streaming"}` | 1/0 per standby | Stat / Status grid |

Alert rules (Prometheus `Alertmanager`):

```yaml
groups:
  - name: pg_replication
    rules:
      # No standby connected
      - alert: PGNoStandby
        expr: pg_stat_replication_count == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "No PostgreSQL standby is connected"

      # Standby lag too high
      - alert: PGReplicaLagHigh
        expr: pg_replication_lag{metric="replay_lag_seconds"} > 60
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Standby {{ $labels.application_name }} replay lag > 60s"

      # Replication slot inactive
      - alert: PGSlotInactive
        expr: pg_replication_slot_active == 0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Replication slot {{ $labels.slot_name }} inactive"

      # Slot WAL retention critical
      - alert: PGSlotRetentionHigh
        expr: pg_replication_slot_retained_bytes > 10 * 1024 * 1024 * 1024
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Slot {{ $labels.slot_name }} retaining > 10GB WAL"

      # Total WAL size critical
      - alert: PGWalSizeHigh
        expr: pg_wal_size_bytes > 20 * 1024 * 1024 * 1024
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Total WAL size > 20GB"

      # Snapshot conflict rate high
      - alert: PGConflictRateHigh
        expr: rate(pg_replication_conflicts{conflict_type="snapshot"}[5m]) > 10
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Snapshot conflict rate > 10/sec on {{ $labels.datname }}"
```

### 3.3 Lightweight Patrol Script

For environments without Prometheus, a single SQL check script
can be run via cron (integrated with the existing 5-min patrol).

`~/.kyb/bin/pg-replication-check`:

```bash
#!/bin/bash
set -euo pipefail

DSN="${1:-postgresql://postgres:postgres@127.0.0.1:5432/postgres}"

psql "$DSN" -t -A -F',' <<'SQL'
WITH lag AS (
  SELECT
    application_name,
    client_addr::text,
    sync_state,
    state,
    EXTRACT(epoch FROM replay_lag)::int AS replay_lag_seconds,
    CASE WHEN state = 'streaming' THEN 'ok' ELSE 'warn' END AS status
  FROM pg_stat_replication
  WHERE state IS NOT NULL
),
slots AS (
  SELECT
    slot_name,
    slot_type,
    active,
    COALESCE(wal_status, 'unknown') AS wal_status,
    CASE
      WHEN wal_status IN ('unreserved', 'lost') THEN 'critical'
      WHEN NOT active THEN 'warn'
      ELSE 'ok'
    END AS status
  FROM pg_replication_slots
),
wal_size AS (
  SELECT sum(size) AS wal_bytes FROM pg_ls_waldir()
)
SELECT
  (SELECT json_agg(lag) FROM lag) AS replication,
  (SELECT json_agg(slots) FROM slots) AS slots,
  (SELECT wal_bytes FROM wal_size) AS wal_bytes;
SQL
```

Exit codes:
- `0` — all healthy
- `1` — warnings (lag > 30s, inactive slots)
- `2` — critical (lost slots, no standbys, WAL > 10GB)

The 5-min patrol reads the exit code and reports accordingly.

---

## 4. Integration with Existing Stack

### 4.1 Patrol Hook

Add a check step to `5min-patrol-guide.md`:

```
PG replication check → `pg-replication-check`
- 0 green = all streaming, no lag
- 1 yellow = lag > 30s or inactive slot
- 2 red = lost slot or no standby connected
```

### 4.2 Feishu Alert Routing

| Metric | Severity | Channel |
|---|---|---|
| Standby disconnected / slot lost | P0 | Feishu group @all + TTS notify |
| Lag > 60s for > 2 min | P1 | Feishu group |
| Lag > 30s / inactive slot | P2 | Feishu group (quiet) |
| WAL > 10GB growing | P2 | Feishu group (daily digest if persists) |

### 4.3 Healthcheck for Boss Mode

The boss agent's environment healthcheck should include:

```bash
# Check replication from primary
pg-replication-check $PG_DSN_PRIMARY
case $? in
  0) echo "PG replication: OK";;
  1) echo "PG replication: WARN (lag >30s)";;
  2) echo "PG replication: CRITICAL — investigate";;
esac
```

---

## 5. Alert Fatigue Prevention

| Guard | Implementation |
|---|---|
| Lag must persist N seconds before alert | Prometheus `for: 2m` or patrol consecutive samples |
| Slot inactive — distinguish planned vs. unplanned | Exclude known maintenance windows (label `maintenance=true`) |
| Standby catchup after restart | Suppress lag alerts for 5 min after standby connects |
| WAL growth on cron-heavy workload | Baseline per time-of-day, alert on deviation, not absolute |
| Snapshot conflicts during batch jobs | Track conflict rate, not raw counter — bursts < 10/sec are normal |

---

## 6. Implementation Plan

| Step | What | Who | ETA |
|---|---|---|---|
| 1 | Deploy `postgres_exporter` alongside each PG instance | Ops | 1h |
| 2 | Add custom queries config (`queries.yaml` for slot bytes + conflicts) | Ops | 30m |
| 3 | Create Grafana dashboard (panels per §3.2) | Ops | 1h |
| 4 | Configure Prometheus alert rules | Ops | 30m |
| 5 | Write `pg-replication-check` script, integrate into 5-min patrol | Ops | 30m |
| 6 | Test: stop standby, verify lag alert fires within 2 min | Ops | 30m |
| 7 | Test: drop replication slot, verify slot-lost alert fires | Ops | 15m |
| 8 | Document runbook: "Lost replication slot" recovery procedure | Ops | 30m |

**Total: ~5h**

---

## 7. References

- [PostgreSQL Monitoring — Replication](https://www.postgresql.org/docs/16/monitoring-stats.html#MONITORING-PG-STAT-REPLICATION-VIEW)
- [PostgreSQL Replication Slots](https://www.postgresql.org/docs/16/view-pg-replication-slots.html)
- [pg_stat_database_conflicts](https://www.postgresql.org/docs/16/monitoring-stats.html#MONITORING-PG-STAT-DATABASE-CONFLICTS-VIEW)
- [postgres_exporter](https://github.com/prometheus-community/postgres_exporter)
- [Grafana PostgreSQL Dashboard](https://grafana.com/grafana/dashboards/9628-postgresql-database/)
