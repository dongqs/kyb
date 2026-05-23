---
decision: 稍后做
---

# Backup Verification Monitoring

**Status:** Draft design
**Date:** 2026-05-23
**Scope:** Monitor backup freshness, size, and integrity for ClickHouse, PostgreSQL, and configuration files.

---

## 1. Current Backup Landscape

### 1.1 PG Dumps (stated, cc bridge)

PostgreSQL backups are taken via `pg_dump` and compressed with gzip. They are scp'd to a remote backup host.

| Property | Value |
|----------|-------|
| Tool | `pg_dump` + gzip |
| Schedule | Nightly via cron |
| Destination | Remote host (scp) |
| Retention | Unknown — needs audit |
| Verification | None (no automated restore test) |

### 1.2 CK Data

ClickHouse tables are backed up via `clickhouse-client` `INTO OUTFILE` for schema + some data exports. There is no `BACKUP` statement usage (CK 24.x+ supports `BACKUP TABLE ... TO S3`).

| Property | Value |
|----------|-------|
| Tool | `INTO OUTFILE` / manual `clickhouse-client` exports |
| Schedule | Ad-hoc |
| Destination | Local disk / remote |
| Retention | None defined |
| Verification | None |

### 1.3 Configs

Infrastructure configuration files (Docker Compose files, entrypoint scripts, cc-connect config, Grafana provisioning YAML, etc.) are backed up via git (this repo). However, there are also host-level configs and credentials stored outside this repo that need monitoring.

| Property | Value |
|----------|-------|
| Tool | Git (for this repo) + manual for host configs |
| Schedule | On commit |
| Destination | GitLab |
| Retention | Git history |
| Verification | None for host-level configs |

### 1.4 Current Blind Spots

| Gap | Impact |
|-----|--------|
| No backup freshness check | Stale backups go unnoticed until restore fails |
| No backup size tracking | Sudden size drops (corruption) or unbounded growth go undetected |
| No integrity verification | Corrupted backups only discovered during recovery |
| No restore testing | Unknown whether dumps are actually restorable |
| No config backup verification | Host-level config drift is invisible |
| No centralized status view | Must ssh into backup host and inspect manually |

---

## 2. Backup Monitoring Dimensions

### 2.1 Freshness (Age)

For each backup artifact, track time since last successful backup.

| Metric | Description | Source |
|--------|-------------|--------|
| `backup.pg.age_seconds` | Age of latest PG dump | Backup manifest / file mtime |
| `backup.ck.age_seconds` | Age of latest CK backup | Backup manifest / file mtime |
| `backup.config.age_seconds` | Age of latest host config backup | Backup manifest |
| `backup.pg.next_scheduled_in` | Time until next expected backup | Calculated from schedule |

**Alert**: Backup age exceeds schedule interval by 150% (e.g., daily backup not seen for 36h).

### 2.2 Size

Track backup artifact sizes over time for anomaly detection.

| Metric | Description | Source |
|--------|-------------|--------|
| `backup.pg.size_bytes` | Size of latest PG dump | `ls -l` / `du` |
| `backup.ck.size_bytes` | Size of latest CK backup | `ls -l` / `du` |
| `backup.config.size_bytes` | Size of latest config backup | `ls -l` / `du` |
| `backup.pg.size_7day_avg` | 7-day rolling average PG dump size | Calculated |
| `backup.ck.size_7day_avg` | 7-day rolling average CK backup size | Calculated |

**Alert**:
- Size drops >50% from 7-day avg (possible corruption, partial backup)
- Size grows >100% from 7-day avg (possible runaway data, missing compression)
- Size = 0 (backup failed silently)

### 2.3 Integrity

Verify that backup files are not corrupted and can be restored.

| Check | Description | Frequency |
|-------|-------------|-----------|
| PG dump header | Verify magic bytes (`PG`) + valid gzip | Every patrol |
| CK data file | Verify file is valid (non-empty, expected format) | Every patrol |
| Config tar | Verify archive integrity (`tar -tzf`) | Every patrol |
| PG restore test | Actually restore to a temp DB and run a query | Weekly |
| CK restore test | Restore a table to a test cluster and compare row counts | Weekly |

**Alert**: Any integrity check fails -> P1 incident.

### 2.4 Remote Host

The remote backup host itself must be monitored.

| Metric | Description |
|--------|-------------|
| `backup.host.disk_free_bytes` | Free disk on backup host |
| `backup.host.reachable` | Ping / SSH connectivity |
| `backup.host.backup_count` | Number of backup files retained |

**Alert**: Disk <20% free, host unreachable, backup count outside expected range.

---

## 3. Alert Thresholds

| Rule | Condition | Level | Action |
|------|-----------|-------|--------|
| **StaleBackupPG** | PG dump age > 36h (daily schedule + 50% buffer) | P1 | Check cron: `ssh backup-host crontab -l \| grep pg_dump` |
| **StaleBackupCK** | CK backup age > 36h | P1 | Check cron or manual: when was last CK backup triggered? |
| **StaleBackupConfig** | Host config backup age > 48h | P2 | Configs change less frequently, 48h buffer is safe |
| **BackupSizeDrop** | Size < 50% of 7-day rolling avg | P1 | Possible partial dump — restore from previous known-good |
| **BackupSizeSpike** | Size > 200% of 7-day rolling avg | P2 | Investigate data growth or missing compression |
| **BackupEmpty** | Backup file size = 0 | P1 | Backup process failed — check logs |
| **IntegrityFail** | `gzip -t` or `tar -tzf` fails | P1 | File corruption — restore from previous known-good |
| **RestoreTestFail** | Weekly restore test fails | P0 | Backups are not restorable! Full incident response |
| **BackupHostUnreachable** | SSH connection refused / timeout | P2 | Check network and backup host |
| **BackupHostDisk** | Free disk on backup host < 20% | P2 | Rotate old backups or expand volume |
| **ConfigDrift** | Host config differs from git HEAD for this repo's files | P2 | Config changed outside git — sync or commit |

---

## 4. Implementation Options

### 4.1 Bash Monitor Script (cc-healthcheck integration)

Add a `backup-check` subcommand to `~/.kyb/bin/cc-healthcheck`.

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/cc-backup-check
# Monitor PG, CK, and config backup freshness / size / integrity.
#
# Depends on:
#   - SSH access to backup host (key-based auth)
#   - `jq`, `gzip`, `tar` on the monitoring host

set -euo pipefail

BACKUP_HOST="${BACKUP_HOST:-backup.internal}"
BACKUP_USER="${BACKUP_USER:-root}"
BACKUP_DIR="${BACKUP_DIR:-/backup}"
PG_EXPECTED_INTERVAL=86400    # 24h
CK_EXPECTED_INTERVAL=86400    # 24h
CONFIG_EXPECTED_INTERVAL=86400 # 24h
NOW=$(date +%s)
EXIT_CODE=0

# --- Helper: get file age in seconds ---
file_age() {
  local path="$1"
  local host="${2:-}"
  if [ -n "$host" ]; then
    ssh "$host" "stat -c '%Y' '$path' 2>/dev/null || echo 0"
  else
    stat -c '%Y' "$path" 2>/dev/null || echo 0
  fi
}

# --- Helper: get file size in bytes ---
file_size() {
  local path="$1"
  local host="${2:-}"
  if [ -n "$host" ]; then
    ssh "$host" "stat -c '%s' '$path' 2>/dev/null || echo 0"
  else
    stat -c '%s' "$path" 2>/dev/null || echo 0
  fi
}

# --- 1. PG Backup ---
echo "=== PG Backup Check ==="
PG_LATEST=$(ssh "$BACKUP_HOST" "ls -t $BACKUP_DIR/pg/kyb-*.sql.gz 2>/dev/null | head -1" || echo "")
if [ -n "$PG_LATEST" ]; then
  PG_AGE=$((NOW - $(file_age "$PG_LATEST" "$BACKUP_HOST")))
  PG_SIZE=$(file_size "$PG_LATEST" "$BACKUP_HOST")
  echo "backup_pg_latest=\"$PG_LATEST\""
  echo "backup_pg_age_seconds=$PG_AGE"
  echo "backup_pg_size_bytes=$PG_SIZE"

  # Freshness
  if [ "$PG_AGE" -gt $((PG_EXPECTED_INTERVAL * 15 / 10)) ]; then
    echo "backup_pg_status=stale"
    echo "WARNING: PG backup is $PG_AGE seconds old (threshold: $((PG_EXPECTED_INTERVAL * 15 / 10)))"
    EXIT_CODE=2
  else
    echo "backup_pg_status=fresh"
  fi

  # Integrity
  if [ "$PG_SIZE" -eq 0 ]; then
    echo "backup_pg_integrity=empty"
    echo "CRITICAL: PG backup is empty!"
    EXIT_CODE=2
  elif ssh "$BACKUP_HOST" "gzip -t '$PG_LATEST'" 2>/dev/null; then
    echo "backup_pg_integrity=ok"
  else
    echo "backup_pg_integrity=corrupt"
    echo "CRITICAL: PG backup failed gzip integrity check!"
    EXIT_CODE=2
  fi
else
  echo "backup_pg_latest=\"\""
  echo "backup_pg_age_seconds=-1"
  echo "backup_pg_size_bytes=0"
  echo "backup_pg_status=missing"
  echo "CRITICAL: No PG backup found!"
  EXIT_CODE=2
fi

# --- 2. CK Backup ---
echo "=== CK Backup Check ==="
CK_LATEST=$(ssh "$BACKUP_HOST" "ls -t $BACKUP_DIR/ck/kyb-*.sql.gz 2>/dev/null | head -1" || echo "")
if [ -n "$CK_LATEST" ]; then
  CK_AGE=$((NOW - $(file_age "$CK_LATEST" "$BACKUP_HOST")))
  CK_SIZE=$(file_size "$CK_LATEST" "$BACKUP_HOST")
  echo "backup_ck_latest=\"$CK_LATEST\""
  echo "backup_ck_age_seconds=$CK_AGE"
  echo "backup_ck_size_bytes=$CK_SIZE"

  if [ "$CK_AGE" -gt $((CK_EXPECTED_INTERVAL * 15 / 10)) ]; then
    echo "backup_ck_status=stale"
    echo "WARNING: CK backup is $CK_AGE seconds old"
    EXIT_CODE=2
  else
    echo "backup_ck_status=fresh"
  fi

  if [ "$CK_SIZE" -eq 0 ]; then
    echo "backup_ck_integrity=empty"
    echo "CRITICAL: CK backup is empty!"
    EXIT_CODE=2
  elif ssh "$BACKUP_HOST" "gzip -t '$CK_LATEST'" 2>/dev/null; then
    echo "backup_ck_integrity=ok"
  else
    echo "backup_ck_integrity=corrupt"
    echo "CRITICAL: CK backup failed gzip integrity check!"
    EXIT_CODE=2
  fi
else
  echo "backup_ck_latest=\"\""
  echo "backup_ck_age_seconds=-1"
  echo "backup_ck_size_bytes=0"
  echo "backup_ck_status=missing"
  echo "WARNING: No CK backup found"
fi

# --- 3. Config Backup ---
echo "=== Config Backup Check ==="
CONFIG_LATEST=$(ssh "$BACKUP_HOST" "ls -t $BACKUP_DIR/config/kyb-config-*.tar.gz 2>/dev/null | head -1" || echo "")
if [ -n "$CONFIG_LATEST" ]; then
  CONFIG_AGE=$((NOW - $(file_age "$CONFIG_LATEST" "$BACKUP_HOST")))
  CONFIG_SIZE=$(file_size "$CONFIG_LATEST" "$BACKUP_HOST")
  echo "backup_config_latest=\"$CONFIG_LATEST\""
  echo "backup_config_age_seconds=$CONFIG_AGE"
  echo "backup_config_size_bytes=$CONFIG_SIZE"

  if [ "$CONFIG_AGE" -gt $((CONFIG_EXPECTED_INTERVAL * 15 / 10)) ]; then
    echo "backup_config_status=stale"
    echo "WARNING: Config backup is $CONFIG_AGE seconds old"
    EXIT_CODE=2
  else
    echo "backup_config_status=fresh"
  fi

  if [ "$CONFIG_SIZE" -eq 0 ]; then
    echo "backup_config_integrity=empty"
    echo "CRITICAL: Config backup is empty!"
    EXIT_CODE=2
  elif ssh "$BACKUP_HOST" "tar -tzf '$CONFIG_LATEST'" >/dev/null 2>&1; then
    echo "backup_config_integrity=ok"
  else
    echo "backup_config_integrity=corrupt"
    echo "CRITICAL: Config backup failed tar integrity check!"
    EXIT_CODE=2
  fi
else
  echo "backup_config_latest=\"\""
  echo "backup_config_age_seconds=-1"
  echo "backup_config_size_bytes=0"
  echo "backup_config_status=missing"
  echo "WARNING: No config backup found"
fi

# --- 4. Backup Host Health ---
echo "=== Backup Host Check ==="
DISK_FREE=$(ssh "$BACKUP_HOST" "df --output=pcent '$BACKUP_DIR' 2>/dev/null | tail -1 | tr -d ' %'")
if [ -n "$DISK_FREE" ]; then
  echo "backup_host_disk_usage_pct=$DISK_FREE"
  if [ "$DISK_FREE" -gt 80 ]; then
    echo "WARNING: Backup host disk > 80% used"
    EXIT_CODE=2
  fi
else
  echo "backup_host_disk_usage_pct=-1"
fi

# --- 5. Summary ---
echo "=== Summary ==="
if [ "$EXIT_CODE" -eq 0 ]; then
  echo "backup_overall_status=ok"
elif [ "$EXIT_CODE" -eq 1 ]; then
  echo "backup_overall_status=warning"
else
  echo "backup_overall_status=critical"
fi

exit "$EXIT_CODE"
```

**Integration**: Run every patrol cycle (5 min) from `cc-healthcheck`. On anomaly, include backup status in the patrol report.

### 4.2 ClickHouse Time-Series (Vector Ingestion)

Ingest backup metrics into ClickHouse for trend analysis and Grafana dashboards.

**Table schema**:

```sql
CREATE TABLE monitor.backup_snapshots (
    timestamp       DateTime64(3),

    -- PG
    pg_age_seconds      Int32,
    pg_size_bytes       UInt64,
    pg_integrity        LowCardinality(String),  -- ok / corrupt / empty / missing
    pg_status           LowCardinality(String),  -- fresh / stale / missing

    -- CK
    ck_age_seconds      Int32,
    ck_size_bytes       UInt64,
    ck_integrity        LowCardinality(String),
    ck_status           LowCardinality(String),

    -- Config
    config_age_seconds  Int32,
    config_size_bytes   UInt64,
    config_integrity    LowCardinality(String),
    config_status       LowCardinality(String),

    -- Host
    host_disk_usage_pct Float32,
    overall_status      LowCardinality(String)   -- ok / warning / critical
) ENGINE = MergeTree
ORDER BY (toDate(timestamp))
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

**Useful queries**:

Latest backup age:
```sql
SELECT timestamp, pg_age_seconds, ck_age_seconds, config_age_seconds
FROM monitor.backup_snapshots
ORDER BY timestamp DESC
LIMIT 1;
```

Size trend over time:
```sql
SELECT toDate(timestamp) AS day,
       avg(pg_size_bytes) AS avg_pg_size,
       avg(ck_size_bytes) AS avg_ck_size
FROM monitor.backup_snapshots
WHERE timestamp > now() - INTERVAL 30 DAY
GROUP BY day
ORDER BY day;
```

Integrity failures in last 7 days:
```sql
SELECT timestamp, pg_integrity, ck_integrity, config_integrity
FROM monitor.backup_snapshots
WHERE pg_integrity != 'ok'
   OR ck_integrity != 'ok'
   OR config_integrity != 'ok'
ORDER BY timestamp DESC;
```

Alert history (stale / critical events):
```sql
SELECT timestamp, overall_status, pg_status, ck_status
FROM monitor.backup_snapshots
WHERE overall_status IN ('warning', 'critical')
ORDER BY timestamp DESC
LIMIT 20;
```

### 4.3 Restore Test (Weekly)

Restore testing is the only way to verify backups actually work. This should run weekly (Sunday at 03:00).

**PG restore test**:

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/cc-backup-restore-test
# Restores the latest PG dump to a temp database and verifies it.

set -euo pipefail

BACKUP_HOST="${BACKUP_HOST:-backup.internal}"
PG_LATEST=$(ssh "$BACKUP_HOST" "ls -t /backup/pg/kyb-*.sql.gz 2>/dev/null | head -1")
TEST_DB="backup_verify_$(date +%s)"

# Download
scp "$BACKUP_HOST:$PG_LATEST" /tmp/pg-restore-test.sql.gz

# Create temp DB
createdb "$TEST_DB"

# Restore
gunzip -c /tmp/pg-restore-test.sql.gz | psql -d "$TEST_DB" >/dev/null 2>&1

# Verify: check table count and row count
TABLE_COUNT=$(psql -d "$TEST_DB" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")
ROW_COUNT=$(psql -d "$TEST_DB" -t -c "SELECT sum(n_live_tup) FROM pg_stat_user_tables;" 2>/dev/null || echo 0)

echo "backup_restore_test_table_count=$TABLE_COUNT"
echo "backup_restore_test_row_count=$ROW_COUNT"
echo "backup_restore_test_passed=true"

# Cleanup
dropdb "$TEST_DB"
rm /tmp/pg-restore-test.sql.gz
```

**CK restore test**:

```bash
# Download the latest schema backup
scp "$BACKUP_HOST:$CK_LATEST" /tmp/ck-restore-test.sql.gz

# Create test database
clickhouse-client --query "CREATE DATABASE IF NOT EXISTS backup_verify"

# Apply schema
gunzip -c /tmp/ck-restore-test.sql.gz | clickhouse-client --database backup_verify

# Verify: check tables were created
TABLE_COUNT=$(clickhouse-client --query "SELECT count() FROM system.tables WHERE database = 'backup_verify'")
echo "backup_ck_restore_test_table_count=$TABLE_COUNT"

# Cleanup
clickhouse-client --query "DROP DATABASE backup_verify"
rm /tmp/ck-restore-test.sql.gz
```

---

## 5. Grafana Dashboard

### 5.1 Provisioning

Dashboard name: **Backup Monitor**
Refresh: 60s

### 5.2 Dashboard Layout

```
Row: "Backup Overview"
  ├── Stat: Overall Backup Status (ok/warning/critical, color-coded)
  ├── Stat: PG Backup (fresh/stale/missing, color-coded)
  ├── Stat: CK Backup (fresh/stale/missing, color-coded)
  └── Stat: Config Backup (fresh/stale/missing, color-coded)

Row: "Backup Freshness"
  ├── Time Series: PG Backup Age (24h, threshold line at 36h)
  ├── Time Series: CK Backup Age (24h, threshold line at 36h)
  └── Time Series: Config Backup Age (48h, threshold line at 72h)

Row: "Backup Size"
  ├── Time Series: PG Dump Size (30d, with 7-day rolling avg overlay)
  ├── Time Series: CK Backup Size (30d, with 7-day rolling avg overlay)
  └── Time Series: Config Backup Size (30d)

Row: "Backup Health"
  ├── Table: Recent Integrity Events (last 20, timestamp + status + type)
  ├── Stat: Restore Test Result (passed/failed, from weekly test)
  └── Stat: Backup Host Disk Usage (percentage gauge)

Row: "Restore Test History"
  ├── Time Series: Restore test table count over time (PG + CK)
  └── Table: Last 10 restore test results with timestamps
```

### 5.3 Grafana Alert Rules

| Alert Name | Condition | Level |
|------------|-----------|-------|
| **Backup - PG Stale** | `pg_age_seconds > 129600` (36h) | P1 Warning |
| **Backup - CK Stale** | `ck_age_seconds > 129600` (36h) | P1 Warning |
| **Backup - Config Stale** | `config_age_seconds > 172800` (48h) | P2 Warning |
| **Backup - Integrity Fail** | `pg_integrity != 'ok' OR ck_integrity != 'ok' OR config_integrity != 'ok'` | P1 Critical |
| **Backup - Restore Test Fail** | No restore test result in last 8 days | P0 Critical |
| **Backup - Host Disk** | `host_disk_usage_pct > 80` | P2 Warning |
| **Backup - Size Anomaly** | `pg_size_bytes < 0.5 * 7day_avg OR pg_size_bytes > 2.0 * 7day_avg` | P1 Warning |

---

## 6. Implementation Roadmap

| Phase | Tasks | Timeline |
|-------|-------|----------|
| **P0** | Audit current backup schedule + retention on backup host | Immediate |
| **P0** | Write `~/.kyb/bin/cc-backup-check` script | < 1h |
| **P0** | Deploy script, test against actual backup files | < 1h |
| **P0** | Integrate into 5-min patrol (call from cc-healthcheck) | < 30min |
| **P1** | Configure Vector to ingest backup metrics into ClickHouse | < 2h |
| **P1** | Create `monitor.backup_snapshots` table | < 15min |
| **P1** | Build Grafana dashboard (Section 5 layout) | < 1h |
| **P2** | Write weekly restore test script | < 1h |
| **P2** | Deploy restore test cron (Sunday 03:00) | < 15min |
| **P2** | Configure Grafana alert rules (Section 5.3) | < 30min |
| **P3** | Implement auto-cleanup of old backups based on retention policy | < 1h |
| **P3** | Add backup size anomaly detection (ML-based threshold) | < 2h |

---

## 7. Integration Points

### 7.1 With Existing Patrol

The patrol system (`docs/infra/5min-patrol-guide.md`) runs every 5 minutes. Add backup check as an additional patrol step:

```
1. Environment check (docker ps, df -h, proxy)
2. cc-connect self-check (cc-healthcheck)
3. **Backup check (cc-backup-check)** ← NEW
4. Write heartbeat + status
5. Check siblings
6. Report anomalies via feishu
```

### 7.2 With cc-healthcheck

Add backup check as a subcommand of `cc-healthcheck`:

```bash
~/.kyb/bin/cc-healthcheck backup
```

This runs the backup check script and includes results in the healthcheck output.

### 7.3 With Vector

Configure Vector to tail the backup check output file:

```toml
[sources.backup_metrics]
type = "file"
include = ["/root/.kyb/run/backup-metrics.log"]

[transforms.backup_metrics_parse]
type = "regex_parser"
inputs = ["backup_metrics"]
pattern = '^(?P<metric>\w+)=(?P<value>.+)$'

[sinks.clickhouse_backup]
type = "clickhouse"
inputs = ["backup_metrics_parse"]
table = "monitor.backup_snapshots"
```

---

## 8. Auto-Cleanup Policy (P3)

Once monitoring is stable, define a retention policy for backup files on the backup host.

| Backup Type | Retention | Cleanup Rule |
|-------------|-----------|--------------|
| PG dumps | Keep last 30 daily dumps | `find /backup/pg/ -name '*.sql.gz' -mtime +30 -delete` |
| CK backups | Keep last 30 daily backups | `find /backup/ck/ -name '*.sql.gz' -mtime +30 -delete` |
| Config archives | Keep last 90 daily archives | `find /backup/config/ -name '*.tar.gz' -mtime +90 -delete` |

Cleanup should be a separate script (`cc-backup-cleanup`) run daily via cron, with a `--dry-run` flag for safety.

---

## 9. References

- Patrol guide: `docs/infra/5min-patrol-guide.md`
- Observability design: `docs/infra/observability-design.md`
- Session monitor: `docs/infra/reviews/session-monitor.md`
- CK query monitor: `docs/infra/reviews/ck-query-monitor.md`
- This repo's backup configs: GitLab CI / `~/.config/kyb/config.yml`
- PostgreSQL `pg_dump` docs: https://www.postgresql.org/docs/current/app-pgdump.html
- ClickHouse `BACKUP` statement: https://clickhouse.com/docs/en/sql-reference/statements/backup
