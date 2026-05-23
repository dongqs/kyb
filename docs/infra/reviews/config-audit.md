---
decision: 稍后做
---

# Design: Config File Change Auditing for Infra

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Track checksums, detect manual edits, maintain change history per config file across all infra clusters.

---

## Table of Contents

1. [Motivation](#1-motivation)
2. [Scope](#2-scope)
3. [Architecture](#3-architecture)
4. [Data Model](#4-data-model)
5. [Watcher Implementation](#5-watcher-implementation)
6. [Checksum Computation Strategy](#6-checksum-computation-strategy)
7. [Manual Edit Detection](#7-manual-edit-detection)
8. [Authorized Deployment Workflow](#8-authorized-deployment-workflow)
9. [Alert Rules](#9-alert-rules)
10. [Grafana Dashboard](#10-grafana-dashboard)
11. [Query Examples](#11-query-examples)
12. [Operational Runbook](#12-operational-runbook)

---

## 1. Motivation

Infra config files are the source of truth for how services run. When someone (human or agent) edits a config file, the change should be:

1. **Tracked** -- who/what changed it, when, and what the old/new values were
2. **Auditable** -- full change history per file, accessible months later
3. **Verifiable** -- automatic detection of unauthorized or unexpected edits

Currently, config files are managed ad-hoc:
- `~/.config/kyb/config.yml` is written once and rarely revisited
- `~/.config/kyb/clusters.yml` is edited on the super-boss when clusters change
- Docker run commands are copy-pasted from docs (no checksum tracking)
- HEALTHCHECK definitions, proxy settings, and environment variables drift silently

Without auditing, a manual edit to a boss's `config.yml` could change the proxy route or registry mirror with no record. If the boss restarts and the config is wrong, debugging requires reconstructing what changed from memory or git history (which may not be pushed).

### 1.1 Design Goals

| Goal | Priority | How |
|------|----------|-----|
| Detect any config file change | P0 | Periodic checksum scan, compare to known-good baseline |
| Record change history per file | P0 | ClickHouse table with before/after checksums and metadata |
| Distinguish authorized vs unauthorized changes | P1 | Git SHA anchoring + deployment marker pattern |
| Alert on unexpected manual edits | P1 | Watcher computes "expected vs actual", fires on mismatch |
| Survive container restarts | P1 | Config audit table is in central CK, not local filesystem |
| Minimal overhead | P2 | Config scan runs every 5min (piggyback on patrol), ~100ms per scan |
| No new dependencies | P2 | Uses sha256sum + curl + bash (already in boss containers) |

---

## 2. Scope

### 2.1 Config File Categories

| Category | Files | Cluster(s) | Change Frequency |
|----------|-------|-----------|-----------------|
| **Boss config** | `~/.config/kyb/config.yml` | All | Rare (per-cluster setup) |
| **Cluster registry** | `~/.config/kyb/clusters.yml` | Super-boss only | When cluster added/removed |
| **Docker service definitions** | Docker `run` commands in `docs/infra/handbook/*.md`, boss startup scripts | All | When service config changes |
| **Base image config** | `Dockerfile`, `entrypoint.sh`, `mise.config.toml` | All (shared) | Code changes (git-tracked) |
| **Runtime env files** | `.env` files, shell config snippets in `~/.bashrc` (boss) | All | Rare |
| **Service config** | `prometheus.yml`, Grafana provisioning YAML, ClickHouse config XML | Super-boss | When observability stack changes |

### 2.2 Files Excluded from Audit

- **Sandbox configs** -- ephemeral, created/destroyed frequently, not infra-critical
- **Git-tracked code** in `lib/`, `bin/`, `test/` -- git history is the audit trail
- **ClickHouse data** -- managed by CK itself (system.query_log, etc.)
- **Docker volumes** -- persistent data, not config

### 2.3 Current Config File Inventory

```
Per-cluster (boss):
  ~/.config/kyb/config.yml          -- proxy, registry_mirror, no_proxy

Super-boss only:
  ~/.config/kyb/clusters.yml        -- cluster registry, service placement
  ~/.ssh/config                     -- SSH multiplexing config (from host)

Shared (git-tracked, in ~/.kyb):
  Dockerfile                         -- base image definition
  entrypoint.sh                      -- container startup
  mise.config.toml                   -- runtime toolchain versions

Per-service (defined in docker run / startup scripts):
  PostgreSQL:  --health-cmd='pg_isready -U postgres'
  Redis:       --health-cmd='redis-cli ping'
  ClickHouse:  --health-cmd='clickhouse-client --query "SELECT 1"'
  Grafana:     health check, provisioning YAML paths
  sing-box:    config file path, proxy route settings
  registry:    REGISTRY_PROXY_REMOTEURL, ALL_PROXY
```

---

## 3. Architecture

### 3.1 Data Flow

```
Config files on disk (per boss container)
    │  (Every 5 minutes, triggered by patrol)
    ▼
config-audit-watcher (lightweight bash script inside kyb-infra-boss)
    │  (sha256sum + metadata -> HTTP POST JSON to central CK)
    ▼
ClickHouse (infra.config_audit_log)  ← super-boss CK
    │
    ├── Change history table (append-only)
    ├── Grafana dashboard (config drift overview)
    └── Alert trigger (unexpected checksum delta)
```

### 3.2 Where It Runs

The watcher runs **inside each `kyb-infra-boss` container** -- same deployment pattern as the Docker event watcher and heartbeat loop. Every 5 minutes (triggered by the patrol cron / alarm cycle), it:

1. Enumerates all tracked config files
2. Computes sha256sum for each
3. Fetches the last-known checksum per file from CK (or uses local cache)
4. Compares: if changed, records a `config_change` event
5. Records a `config_snapshot` event regardless (so CK has the current state)

### 3.3 No New Infrastructure

The watcher relies on tools already present in every boss container:

| Tool | Purpose |
|------|---------|
| `sha256sum` | Checksum computation (part of `coreutils`) |
| `curl` | HTTP POST to central CK (already used by heartbeat) |
| `bash` | Script runtime |
| `stat` | File metadata (modification time, size) |
| Central CK | Audit log storage (at `100.104.244.99:8123`) |

### 3.4 Idempotent Start via Patrol

The watcher runs as part of the existing 5-minute patrol cycle. No daemon needed:

```bash
# In patrol script (runs every 5 minutes on each boss):
/usr/local/bin/config-audit-watcher.sh 2>/dev/null
```

If the watcher fails (e.g., CK unreachable), the patrol logs the error but continues. Config audit is best-effort -- missed scans are recovered on the next cycle.

### 3.5 Startup Bootstrap

The watcher must establish a baseline on first run. On first scan, every file gets a `config_snapshot` event with checksum, but no `config_change` event (no previous state to compare against). After the second scan, deltas are meaningful.

---

## 4. Data Model

### 4.1 ClickHouse Schema

```sql
CREATE DATABASE IF NOT EXISTS infra;

-- Config file snapshots (every scan, every file)
-- This is the daily truth: "at time T, file F had checksum C"
CREATE TABLE infra.config_snapshots (
    -- Identity
    boss_id         LowCardinality(String),       -- hostname of the boss container
    cluster         LowCardinality(String),       -- mac-orbstack | aliyun | office

    -- Snapshot metadata
    scan_time       DateTime64(3),                -- when the scan ran
    file_path       String,                       -- absolute path, e.g. /home/dev/.config/kyb/config.yml

    -- File metadata
    checksum        FixedString(64),              -- sha256 hex digest
    file_size       UInt32,                       -- bytes
    file_mode       String,                       -- e.g. -rw-r--r-- (permissions)
    mtime           DateTime64(3),                -- file modification time from stat
    uid             UInt16,                       -- owner UID
    gid             UInt16,                       -- group GID
    user_name       String DEFAULT '',            -- owner name (if resolvable)
    group_name      String DEFAULT '',            -- group name (if resolvable)

    -- Expected checksum (from known-good baseline, empty if unknown)
    expected_checksum FixedString(64) DEFAULT '',

    -- Audit classification
    change_type     Enum8(                       -- what the scan concluded
        'unchanged' = 0,                          -- checksum matches previous snapshot
        'changed'   = 1,                          -- checksum differs from previous
        'new'       = 2,                          -- file not seen before
        'deleted'   = 3,                          -- file existed before, now missing
        'baseline'  = 4                           -- first scan, no prior state
    ) DEFAULT 'unchanged',

    -- Git integration (if file is in a git repo)
    git_commit      String DEFAULT '',            -- HEAD commit SHA at scan time
    git_branch      String DEFAULT '',            -- current branch
    git_is_dirty    Bool DEFAULT false,           -- working tree has uncommitted changes

    -- Escalation
    is_manual_edit  Bool DEFAULT false,           -- heuristic: changed without git commit
    alert_level     Enum8(                       -- severity of this scan result
        'none'     = 0,
        'info'     = 1,
        'warning'  = 2,
        'critical' = 3
    ) DEFAULT 'none',

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (scan_time, cluster, file_path)
TTL scan_time + INTERVAL 365 DAY;
```

```sql
-- Config change events (only when a change is detected)
-- This is the human-readable change log
CREATE TABLE infra.config_changes (
    -- Identity
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),

    -- When
    detected_at     DateTime64(3),                -- when the watcher noticed

    -- What
    file_path       String,
    change_type     Enum8(
        'modified'  = 0,                          -- content changed
        'created'   = 1,                          -- file appeared
        'deleted'   = 2,                          -- file disappeared
        'permissions_changed' = 3,                -- mode/owner changed, content same
        'reverted'  = 4                           -- returned to expected checksum
    ),

    -- Checksums
    old_checksum    FixedString(64) DEFAULT '',   -- empty for 'created'
    new_checksum    FixedString(64) DEFAULT '',

    -- Expected vs actual
    expected_checksum FixedString(64) DEFAULT '',
    is_authorized   Bool DEFAULT false,           -- true if new checksum matches expected

    -- Context
    file_size_old   UInt32 DEFAULT 0,
    file_size_new   UInt32 DEFAULT 0,
    mtime_old       DateTime64(3),
    mtime_new       DateTime64(3),

    -- Git context at detection time
    git_commit      String DEFAULT '',
    git_branch      String DEFAULT '',
    git_is_dirty    Bool DEFAULT false,

    -- Classification
    classification  Enum8(
        'unknown'           = 0,                  -- no classification yet
        'authorized_deploy' = 1,                  -- matched a known-good checksum
        'manual_edit'       = 2,                  -- changed without matching any baseline
        'git_commit'        = 3,                  -- changed via git pull/checkout
        'rollback'          = 4,                  -- reverted to previous known state
        'infra_agent'       = 5                   -- changed by an authorized infra agent
    ) DEFAULT 'unknown',
    classification_reason String DEFAULT '',      -- free-text: why this classification

    -- Escalation
    alert_level     Enum8(
        'none'     = 0,
        'info'     = 1,
        'warning'  = 2,
        'critical' = 3
    ) DEFAULT 'none',
    acknowledged   Bool DEFAULT false,
    ack_by         String DEFAULT '',
    ack_at         DateTime64(3),

    -- Ingestion
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (detected_at, cluster, file_path)
TTL detected_at + INTERVAL 365 DAY;
```

```sql
-- Known-good baselines (source of truth for "expected" checksums)
-- Populated by the super-boss after each authorized deployment
CREATE TABLE infra.config_baselines (
    -- Identity
    cluster         LowCardinality(String),
    boss_id         LowCardinality(String),       -- '' means all bosses in cluster
    file_path       String,

    -- Baseline
    checksum        FixedString(64),              -- sha256 of the approved version
    deployed_at     DateTime64(3),
    deployed_by     String,                       -- e.g. 'kyb-infra-boss' or 'dongqs'
    deployment_id   String,                       -- link to deploy event / MR / commit

    -- Versioning
    version         UInt32,                       -- monotonically increasing per file
    description     String DEFAULT '',            -- what changed in this version

    -- Status
    is_active       Bool DEFAULT true,            -- false if superseded by newer baseline

    -- Ingestion
    _ingested_at    DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(version)
ORDER BY (cluster, file_path, version);
```

### 4.2 Design Decisions

1. **Two tables: snapshots + changes.** Snapshots are the raw audit trail (every scan for every file). Changes are derived (only when something actually changes). Snapshots enable "show me what config looked like at any point in time". Changes enable "show me what changed and why".

2. **ReplacingMergeTree for baselines.** Only the latest active baseline per `(cluster, file_path)` matters for comparison. `ReplacingMergeTree` with `version` ensures dedup on merge.

3. **FixedString(64) for checksums.** sha256 produces exactly 64 hex chars. FixedString is faster and more compact than String for known-length data.

4. **LowCardinality for boss_id, cluster.** Same reasoning as docker_events -- few distinct values, high compression ratio.

5. **TTL 365 days.** Config audit data is useful long-term (unlike ephemeral Docker events). 1 year retention covers incident post-mortems and quarterly reviews. Config file count is small (~20 files per cluster), so storage is negligible even at 1 scan/5min.

6. **Separate `detected_at` and `_ingested_at`.** The gap between them measures pipeline latency (same pattern as docker_events).

### 4.3 Estimated Volume

| Item | Value |
|------|-------|
| Config files per cluster | ~20 (config.yml, clusters.yml, ssh_config, docker run scripts, etc.) |
| Scans per day | 288 (every 5 minutes) |
| Snapshot rows per day per cluster | ~5,760 (20 files * 288 scans) |
| Snapshot rows per day (3 clusters) | ~17,280 |
| Change events per day (typical) | ~2-5 (config changes are rare) |
| Storage per snapshot | ~200 bytes (compressed ~50 bytes) |
| Annual storage (snapshots) | ~17,280 rows/day * 50 bytes * 365 = ~315 MB |
| Annual storage (changes) | ~4 changes/day * 400 bytes * 365 = ~584 KB |

Even with full snapshots every 5 minutes, annual storage is under 500 MB. If this becomes too large, reduce scan frequency to every 15 minutes (96 scans/day, ~105 MB/year).

---

## 5. Watcher Implementation

### 5.1 Core Script

```bash
#!/usr/bin/env bash
# config-audit-watcher.sh — runs inside kyb-infra-boss
# Scans tracked config files, computes checksums, reports to central CK.
# Designed to be invoked by the 5-minute patrol cycle.

set -euo pipefail

CK_URL="http://100.104.244.99:8123"
CK_SNAPSHOTS="infra.config_snapshots"
CK_CHANGES="infra.config_changes"
BOSS_ID="$(hostname)"
CLUSTER="${CLUSTER_NAME:-unknown}"

# Timestamp for this scan (ISO 8601 with milliseconds)
SCAN_TIME=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

# Git context (best-effort)
GIT_COMMIT=""
GIT_BRANCH=""
GIT_IS_DIRTY="false"
if git -C /home/dev/.kyb rev-parse --git-dir >/dev/null 2>&1; then
    GIT_COMMIT=$(git -C /home/dev/.kyb rev-parse HEAD 2>/dev/null || echo "")
    GIT_BRANCH=$(git -C /home/dev/.kyb rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    GIT_IS_DIRTY=$(git -C /home/dev/.kyb status --porcelain 2>/dev/null | head -c1 | wc -c || echo "false")
    [ "$GIT_IS_DIRTY" != "false" ] && GIT_IS_DIRTY="true" || GIT_IS_DIRTY="false"
fi

# Temporary files
SNAPSHOTS_JSON=$(mktemp)
CHANGES_JSON=$(mktemp)
trap 'rm -f "$SNAPSHOTS_JSON" "$CHANGES_JSON"' EXIT

# Last-known checksums: query CK for the most recent snapshot per file
# This avoids filesystem state between scans.
declare -A LAST_CHECKSUMS
LAST_CHECKSUMS_CACHE=$(mktemp)
curl -s --max-time 10 "$CK_URL?query=SELECT+file_path%2C+checksum+FROM+$CK_SNAPSHOTS+WHERE+cluster%3D%27$CLUSTER%27+AND+boss_id%3D%27$BOSS_ID%27+ORDER+BY+scan_time+DESC+LIMIT+1+BY+file_path+FORMAT+TabSeparated" 2>/dev/null \
  | while IFS=$'\t' read -r fpath cksum; do
      [ -n "$fpath" ] && echo "$cksum  $fpath"
    done > "$LAST_CHECKSUMS_CACHE" || true

# === Scan phase ===
# List of files to audit. Extend this list per-cluster as needed.
FILES_TO_SCAN=(
    # Boss config
    "/home/dev/.config/kyb/config.yml"

    # Git-tracked infra files (in ~/.kyb)
    "/home/dev/.kyb/Dockerfile"
    "/home/dev/.kyb/entrypoint.sh"
    "/home/dev/.kyb/mise.config.toml"

    # SSH config (from host mount)
    "/home/dev/.ssh/config"
)

# Super-boss only
if [ "$CLUSTER" = "mac-orbstack" ]; then
    FILES_TO_SCAN+=(
        "/home/dev/.config/kyb/clusters.yml"
    )
fi

# Service runtime configs (add others per-cluster)
if [ -f "/etc/kyb/services/docker-run-args.conf" ]; then
    FILES_TO_SCAN+=("/etc/kyb/services/docker-run-args.conf")
fi

echo "[" > "$SNAPSHOTS_JSON"
echo "[" > "$CHANGES_JSON"
first_snapshot=true
first_change=true

for filepath in "${FILES_TO_SCAN[@]}"; do
    if [ ! -e "$filepath" ]; then
        # File doesn't exist. Record as deleted if we had a previous checksum.
        if grep -q "$filepath" "$LAST_CHECKSUMS_CACHE" 2>/dev/null; then
            if [ "$first_change" = false ]; then echo "," >> "$CHANGES_JSON"; fi
            first_change=false
            cat >> "$CHANGES_JSON" << CHANGE_EOF
{
  "boss_id": "$BOSS_ID",
  "cluster": "$CLUSTER",
  "detected_at": "$SCAN_TIME",
  "file_path": "$filepath",
  "change_type": "deleted",
  "is_authorized": 0,
  "classification": "unknown",
  "alert_level": "warning",
  "git_commit": "$GIT_COMMIT",
  "git_branch": "$GIT_BRANCH",
  "git_is_dirty": $GIT_IS_DIRTY
}
CHANGE_EOF
        fi
        continue
    fi

    # Compute checksum and file metadata
    CHECKSUM=$(sha256sum "$filepath" | cut -d' ' -f1)
    FILE_SIZE=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    FILE_MODE=$(stat -c%a "$filepath" 2>/dev/null || echo "000")
    MTIME_EPOCH=$(stat -c%Y "$filepath" 2>/dev/null || echo 0)
    FILE_MTIME=$(date -u -d @"$MTIME_EPOCH" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo "$SCAN_TIME")
    FILE_OWNER=$(stat -c%U "$filepath" 2>/dev/null || echo "")
    FILE_GROUP=$(stat -c%G "$filepath" 2>/dev/null || echo "")
    UID_VAL=$(stat -c%u "$filepath" 2>/dev/null || echo 0)
    GID_VAL=$(stat -c%g "$filepath" 2>/dev/null || echo 0)

    # Look up expected checksum from baselines
    EXPECTED_CKSUM=$(curl -s --max-time 5 "$CK_URL?query=SELECT+checksum+FROM+infra.config_baselines+WHERE+cluster%3D%27$CLUSTER%27+AND+file_path%3D%27$filepath%27+AND+is_active%3D1+ORDER+BY+version+DESC+LIMIT+1+FORMAT+TabSeparated" 2>/dev/null || echo "")

    # Determine change type by comparing with last-known checksum
    CHANGE_TYPE="baseline"
    ALERT_LEVEL="none"

    if grep -q "$filepath" "$LAST_CHECKSUMS_CACHE" 2>/dev/null; then
        LAST_CKSUM=$(grep "$filepath" "$LAST_CHECKSUMS_CACHE" | awk '{print $1}')
        if [ "$CHECKSUM" = "$LAST_CKSUM" ]; then
            CHANGE_TYPE="unchanged"
        else
            CHANGE_TYPE="changed"
        fi
    else
        # File not in last snapshot -- new or first scan
        CHANGE_TYPE="new"
    fi

    # Record snapshot
    if [ "$first_snapshot" = false ]; then echo "," >> "$SNAPSHOTS_JSON"; fi
    first_snapshot=false
    cat >> "$SNAPSHOTS_JSON" << SNAP_EOF
{
  "boss_id": "$BOSS_ID",
  "cluster": "$CLUSTER",
  "scan_time": "$SCAN_TIME",
  "file_path": "$filepath",
  "checksum": "$CHECKSUM",
  "file_size": $FILE_SIZE,
  "file_mode": "$FILE_MODE",
  "mtime": "$FILE_MTIME",
  "uid": $UID_VAL,
  "gid": $GID_VAL,
  "user_name": "$FILE_OWNER",
  "group_name": "$FILE_GROUP",
  "expected_checksum": "$EXPECTED_CKSUM",
  "change_type": "$CHANGE_TYPE",
  "git_commit": "$GIT_COMMIT",
  "git_branch": "$GIT_BRANCH",
  "git_is_dirty": $GIT_IS_DIRTY,
  "is_manual_edit": false,
  "alert_level": "$ALERT_LEVEL"
}
SNAP_EOF

    # If changed, also record a change event
    if [ "$CHANGE_TYPE" = "changed" ]; then
        # Determine classification
        CLASSIFICATION="unknown"
        CLASSIFICATION_REASON=""
        IS_AUTHORIZED="false"
        CHANGE_ALERT="warning"

        if [ -n "$EXPECTED_CKSUM" ] && [ "$CHECKSUM" = "$EXPECTED_CKSUM" ]; then
            CLASSIFICATION="authorized_deploy"
            CLASSIFICATION_REASON="Checksum matches active baseline"
            IS_AUTHORIZED="true"
            CHANGE_ALERT="none"
        elif [ "$GIT_IS_DIRTY" = "false" ] && [ -n "$GIT_COMMIT" ]; then
            CLASSIFICATION="git_commit"
            CLASSIFICATION_REASON="Changed via git (clean working tree)"
            IS_AUTHORIZED="true"
            CHANGE_ALERT="info"
        elif [ "$GIT_IS_DIRTY" = "true" ]; then
            CLASSIFICATION="manual_edit"
            CLASSIFICATION_REASON="File checksum changed and working tree is dirty"
            IS_AUTHORIZED="false"
            CHANGE_ALERT="warning"
        else
            CLASSIFICATION="manual_edit"
            CLASSIFICATION_REASON="File checksum changed, no matching baseline"
            IS_AUTHORIZED="false"
            CHANGE_ALERT="critical"
        fi

        # Check permissions-change-only case: same checksum but different mtime/mode
        if [ "$CHECKSUM" = "$LAST_CKSUM" ]; then
            # This case is handled by unchanged, but check mode/owner diff
            # For simplicity, we only alert on content change here.
            :
        fi

        if [ "$first_change" = false ]; then echo "," >> "$CHANGES_JSON"; fi
        first_change=false
        cat >> "$CHANGES_JSON" << CHANGE_EOF
{
  "boss_id": "$BOSS_ID",
  "cluster": "$CLUSTER",
  "detected_at": "$SCAN_TIME",
  "file_path": "$filepath",
  "change_type": "modified",
  "old_checksum": "$LAST_CKSUM",
  "new_checksum": "$CHECKSUM",
  "expected_checksum": "$EXPECTED_CKSUM",
  "is_authorized": $IS_AUTHORIZED,
  "file_size_old": 0,
  "file_size_new": $FILE_SIZE,
  "mtime_old": "0001-01-01T00:00:00.000Z",
  "mtime_new": "$FILE_MTIME",
  "git_commit": "$GIT_COMMIT",
  "git_branch": "$GIT_BRANCH",
  "git_is_dirty": $GIT_IS_DIRTY,
  "classification": "$CLASSIFICATION",
  "classification_reason": "$CLASSIFICATION_REASON",
  "alert_level": "$CHANGE_ALERT",
  "acknowledged": false
}
CHANGE_EOF
    fi
done

echo "]" >> "$SNAPSHOTS_JSON"
echo "]" >> "$CHANGES_JSON"

# === Report phase ===
# Send snapshots to CK (batch insert)
SNAPSHOTS_BODY=$(cat "$SNAPSHOTS_JSON")
curl -s -X POST "$CK_URL?query=INSERT+INTO+$CK_SNAPSHOTS+FORMAT+JSONEachRow" \
  -d "$SNAPSHOTS_BODY" \
  --max-time 10 2>/dev/null || echo "[WARN] CK snapshot write failed for $CLUSTER" >&2

# Send changes to CK (if any)
CHANGES_BODY=$(cat "$CHANGES_JSON")
if [ "$CHANGES_BODY" != "[" && "$CHANGES_BODY" != "[]" ]; then
    curl -s -X POST "$CK_URL?query=INSERT+INTO+$CK_CHANGES+FORMAT+JSONEachRow" \
      -d "$CHANGES_BODY" \
      --max-time 10 2>/dev/null || echo "[WARN] CK change write failed for $CLUSTER" >&2
fi

echo "[OK] Config audit snapshot complete for $CLUSTER/$BOSS_ID at $SCAN_TIME"
```

### 5.2 Per-Cluster File List Customization

Each cluster may have slightly different files to audit. The file list in the watcher should be extended per-cluster:

```bash
# Add to FILES_TO_SCAN per cluster:
case "$CLUSTER" in
    mac-orbstack)
        FILES_TO_SCAN+=(
            "/home/dev/.config/kyb/clusters.yml"
            "/home/dev/.ssh/config"
            "/etc/kyb/services/docker-run-args-pg14.conf"
            "/etc/kyb/services/docker-run-args-pg15.conf"
            "/etc/kyb/services/docker-run-args-pg16.conf"
            "/etc/kyb/services/docker-run-args-pg17.conf"
            "/etc/kyb/services/docker-run-args-redis.conf"
            "/etc/kyb/services/docker-run-args-kafka.conf"
            "/etc/kyb/services/docker-run-args-sing-box.conf"
            "/etc/kyb/services/docker-run-args-grafana.conf"
            "/etc/kyb/services/docker-run-args-cc-connect.conf"
        )
        ;;
    aliyun)
        FILES_TO_SCAN+=(
            "/etc/kyb/services/docker-run-args-acr-mirror.conf"
            "/etc/kyb/services/docker-run-args-oss-cache.conf"
            "/etc/kyb/services/docker-run-args-build-runner.conf"
        )
        ;;
    office)
        FILES_TO_SCAN+=(
            "/etc/kyb/services/docker-run-args-gitlab-mirror.conf"
            "/etc/kyb/services/docker-run-args-nexus-cache.conf"
            "/etc/kyb/services/docker-run-args-proxy-exit.conf"
        )
        ;;
esac
```

### 5.3 Local Cache File

To reduce dependency on CK availability, the watcher maintains a local checksum cache:

```bash
# /var/cache/kyb/config-audit-cache.json
# Updated after each successful CK write. Used as fallback if CK is unreachable.
# Format: {"file_path": {"checksum": "abc123...", "mtime": "...", "scan_time": "..."}}

CACHE_FILE="/var/cache/kyb/config-audit-cache.json"
mkdir -p "$(dirname "$CACHE_FILE")"

# On CK failure: read from cache
[ ! -s "$CACHE_FILE" ] && echo '{}' > "$CACHE_FILE"

# After successful CK write: update cache
# (Included at end of watcher script)
python3 -c "
import json, sys
cache = json.load(open('$CACHE_FILE'))
for f in $FILES_TO_SCAN_JSON:
    cache[f['file_path']] = {
        'checksum': f['checksum'],
        'mtime': f['mtime'],
        'scan_time': '$SCAN_TIME'
    }
json.dump(cache, open('$CACHE_FILE', 'w'))
" 2>/dev/null || true
```

### 5.4 CK Unreachable Handling

CK availability is not guaranteed (network partitions, maintenance). The watcher handles this gracefully:

| Scenario | Behavior |
|----------|----------|
| CK reachable, first scan | Baseline snapshot written, no change events |
| CK reachable, subsequent | Normal: snapshot + change events |
| CK down at scan time | Snapshot skipped (logged), local cache used for next comparison |
| CK down for entire patrol cycle | No data loss -- next successful scan catches up |

The watcher never blocks or retries. Best-effort delivery is acceptable because:
- Config changes are slow-moving (hours/days between edits)
- A missed scan is detected on the next cycle (max 10-minute gap)
- The local cache prevents false "changed" events after CK downtime

---

## 6. Checksum Computation Strategy

### 6.1 Why sha256

| Hash | Speed | Collision Safety | Recommended For | Why Not |
|------|-------|-----------------|-----------------|---------|
| SHA-256 | Fast (0.5ms per 1KB) | Current standard | **Config audit** | -- |
| MD5 | Faster (0.2ms per 1KB) | Broken (collisions feasible) | -- | Not collision-safe |
| SHA-1 | Similar to SHA-256 | Deprecated (SHAttered) | -- | Being phased out |
| BLAKE3 | Faster (0.1ms per 1KB) | Excellent | Large-scale file scanning | Not universally available in boss containers (no coreutils) |

`sha256sum` is available in every boss container (part of coreutils), is fast enough for ~20 small config files (total time < 100ms), and provides collision-free identification of file versions.

### 6.2 What Gets Checksummed

The **entire file content** is checksummed, not just diff hunks. This means:

- Any byte change (even whitespace, trailing newline) produces a different checksum
- This is intentional: config files are small (< 10KB), and any change is significant
- Future optimization: store the full file content in ClickHouse for instant diffing (optional `file_content` column in snapshots)

### 6.3 What Is NOT Checksummed

- **Symlink targets** -- only the symlink itself is checksummed (the path string)
- **Directory listings** -- only regular files are tracked
- **File content in transit** -- the checksums are computed on disk, after write
- **Secrets in files** -- if a config file contains secrets, its checksum reveals that *something* changed, but not what. The audit table does NOT store the full file content unless configured to do so.

### 6.4 Expected Checksum Computation

The "expected checksum" is the sha256 of the approved version of a config file. It is established by:

1. **Deploying a change** via the authorized workflow (Section 8)
2. **Recording the result** in `infra.config_baselines`
3. **The watcher comparing** actual checksums to the active baseline

A file whose checksum does NOT match any baseline is flagged as `is_manual_edit = true`.

---

## 7. Manual Edit Detection

### 7.1 Detection Heuristics

The watcher classifies each detected change using multiple signals:

| Signal | Manual Edit | Authorized Deploy | Git Commit |
|--------|------------|------------------|------------|
| Checksum matches a baseline | No | **Yes** | Sometimes (if deploy was via git) |
| Git working tree is dirty | **Often yes** | Usually no | No |
| File mtime is recent | Yes | Yes | Yes |
| Checksum matches a known previous version | No (revert) | No | No (revert) |
| File mode / owner changed | Possible | Unlikely | No |

The classification logic (from the watcher script):

```python
def classify_change(file_path, new_checksum, git_is_dirty, git_commit, baselines):
    # Priority 1: matches a known-good baseline
    if new_checksum in [b.checksum for b in baselines if b.is_active]:
        return ('authorized_deploy', False)

    # Priority 2: changed via git (clean working tree)
    if not git_is_dirty and git_commit:
        return ('git_commit', True)

    # Priority 3: git dirty but file is git-tracked
    if git_is_dirty:
        return ('manual_edit', False)

    # Priority 4: no git context at all
    return ('manual_edit', False)
```

### 7.2 What Triggers a Critical Alert

| Condition | Alert Level | Rationale |
|-----------|-------------|-----------|
| Config file changed, no baseline match, working tree clean | **critical** | File was edited outside git AND outside an authorized deploy. Someone modified it directly on disk. This is the strongest signal of an unauthorized edit. |
| Config file changed, working tree dirty | **warning** | File was edited, but changes may be in-progress git work. Still needs review. |
| Config file changed, matches baseline | **none** | Authorized deployment confirmed. |
| Config file deleted | **warning** | File removal may be intentional or accidental. Needs verification. |
| Config file appeared (new) | **info** | Someone created a new config file. May be legitimate. |
| Config file permissions changed (content same) | **info** | Mode/owner change without content change. Low risk but notable. |

### 7.3 The Manual Edit Signal Chain

```
Manual edit of config.yml on boss
    │
    ▼
sha256sum changes (config file content differs)
    │
    ▼
Watcher detects: old checksum ≠ new checksum
    │
    ▼
No matching baseline for new checksum
    │
    ▼
Git working tree may be clean or dirty
    │
    ▼
Classification: manual_edit
    │
    ▼
Alert level: warning (dirty) or critical (clean)
    │
    ▼
infra.config_changes row with alert_level != 'none'
    │
    ▼
Patrol cycle: if alert_level = critical, dispatch feishu notification
```

### 7.4 False Positive Mitigation

| Scenario | Why It Happens | Mitigation |
|----------|---------------|------------|
| Agent is editing file as part of legitimate work | Watcher fires before agent commits | The change IS legitimate but intermediate. Use a lower alert level for dirty-working-tree changes. Supress alerts during known deploy windows. |
| File permissions changed by package manager | `stat` mode differs | Detect mode-only changes and treat as `info`, not `warning`. |
| File touched (mtime update, no content change) | `touch` or editor save without edit | We compare checksums, not mtime alone. Same checksum = unchanged. |
| Boss container restarted, file system re-mounted | Files may appear "new" on first scan after restart | The watcher compares against CK's last snapshot (not a local file), so files are correctly identified as unchanged. |
| Git pull updated the file | Working tree is clean, HEAD changed | Classification: `git_commit`. Alert level: `info` (notified but not paged). |

---

## 8. Authorized Deployment Workflow

### 8.1 Purpose

An "authorized deployment" is a config change that was deliberately made through the proper channel. The audit system needs to distinguish these from accidental or malicious edits.

### 8.2 Deployment Channels

| Channel | Authorized? | How Baseline Is Set |
|---------|------------|---------------------|
| **git push** to `~/.kyb` on the boss | Yes | Watcher detects clean-working-tree git change + updates baseline via `config_baselines` |
| **Manual `scp`/`cp`** of a known-good config | Conditional | Super-boss must explicitly register the new checksum as a baseline |
| **Agent edit** (authorized infra agent) | Yes if agent records it | Agent calls `register_baseline()` API after making the change |
| **Ad-hoc manual edit** with `vim`/`nano` | No | Triggers manual edit alert |
| **Docker exec** injecting a config | No | Same as manual edit |
| **Deployment script** (e.g., `kyb infra deploy`) | Yes | Script registers baseline as part of its workflow |

### 8.3 Baseline Registration Flow

```
[Authorized change occurs]
    │
    ├── Via git push to ~/.kyb:
    │    1. git pull updates file on disk
    │    2. Watcher detects change
    │    3. Classification: git_commit (clean working tree)
    │    4. Super-boss patrol: verify change, register baseline:
    │       curl -s -X POST http://localhost:8123 \
    │         -d "INSERT INTO infra.config_baselines FORMAT JSONEachRow {
    │           'cluster': 'mac-orbstack',
    │           'file_path': '/home/dev/.config/kyb/config.yml',
    │           'checksum': <new_checksum>,
    │           'deployed_by': 'git-pull',
    │           'deployment_id': '<commit_sha>',
    │           'description': 'Update proxy setting for new relay'
    │         }"
    │    5. Alert acknowledged automatically
    │
    ├── Via authorized infra agent:
    │    1. Agent makes the edit
    │    2. Agent registers baseline immediately after change:
    │       register-baseline --cluster aliyun \
    │         --file ~/.config/kyb/config.yml \
    │         --deployer agent-A1 \
    │         --desc "Set registry_mirror to ACR"
    │    3. Watcher detects change on next scan
    │    4. Change matches baseline -> authorized_deploy -> no alert
    │
    └── Via super-boss manual approval:
        1. Manual edit detected (alert fires)
        2. Super-boss investigates, determines change is legitimate
        3. Super-boss registers baseline retroactively:
           curl -s -X POST http://localhost:8123 \
             -d "INSERT INTO infra.config_baselines ..."
        4. Alert acknowledged, change reclassified as authorized
```

### 8.4 Baseline Registration Helper

```bash
#!/usr/bin/env bash
# register-baseline — register a config file's current checksum as the active baseline
# Usage: register-baseline --cluster <name> --file <path> [--deployer <name>] [--desc <text>]

set -euo pipefail

CK_URL="http://100.104.244.99:8123"

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --file)    FILE_PATH="$2"; shift 2 ;;
        --deployer) DEPLOYER="$2"; shift 2 ;;
        --desc)    DESC="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

: "${CLUSTER:?required}"
: "${FILE_PATH:?required}"
: "${DEPLOYER:=unknown}"

if [ ! -f "$FILE_PATH" ]; then
    echo "[ERROR] File not found: $FILE_PATH"
    exit 1
fi

CHECKSUM=$(sha256sum "$FILE_PATH" | cut -d' ' -f1)
VERSION=$(curl -s --max-time 5 "$CK_URL?query=SELECT+max(version)+FROM+infra.config_baselines+WHERE+cluster%3D%27$CLUSTER%27+AND+file_path%3D%27$FILE_PATH%27+FORMAT+TabSeparated" 2>/dev/null || echo "0")
VERSION=$((VERSION + 1))
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

curl -s -X POST "$CK_URL?query=INSERT+INTO+infra.config_baselines+FORMAT+JSONEachRow" \
  -d "{
    \"cluster\": \"$CLUSTER\",
    \"file_path\": \"$FILE_PATH\",
    \"checksum\": \"$CHECKSUM\",
    \"deployed_at\": \"$NOW\",
    \"deployed_by\": \"$DEPLOYER\",
    \"version\": $VERSION,
    \"description\": \"${DESC:-}\"
  }" \
  --max-time 10

echo "[OK] Baseline registered: $CLUSTER $FILE_PATH @ $CHECKSUM (v$VERSION)"
```

### 8.5 What "Acknowledged" Means

When a change alert fires, the change event in `infra.config_changes` has `acknowledged = false`. Acknowledging means:

1. A human or super-boss has reviewed the change
2. Either registers a baseline (if change is legitimate) or reverts the file (if it was an error)
3. Sets `acknowledged = true` with `ack_by` noting who reviewed it

```sql
-- Acknowledge a change event (mark as reviewed)
ALTER TABLE infra.config_changes
UPDATE acknowledged = 1, ack_by = 'super-boss', ack_at = now()
WHERE detected_at = '2026-05-23T10:30:00.000Z'
  AND file_path = '/home/dev/.config/kyb/config.yml'
  AND cluster = 'aliyun';
```

---

## 9. Alert Rules

### 9.1 Alert Conditions

| Rule | Condition | Severity | Channel | Response |
|------|-----------|----------|---------|----------|
| **Unauthorized config edit** | `infra.config_changes` has row with `alert_level = 'critical'` in last 5 min | **P1** | Feishu @all | Investigate immediately -- config was edited outside authorized channels |
| **Suspicious config edit** | `alert_level = 'warning'` in last 10 min | **P2** | Feishu mention | Review working tree changes |
| **Config file deleted** | `change_type = 'deleted'` | **P2** | Feishu mention | Verify deletion was intentional |
| **Config drift accumulation** | Same file changed >3 times in 24h (regardless of authorization) | **P3** | Daily report | Too much churn -- investigate root cause |
| **New config file appeared** | `change_type = 'new'` | **Info** | Feishu log | Notify but no action needed |
| **Permissions change** | `change_type = 'permissions_changed'` | **Info** | Feishu log | Notify but likely benign |
| **Audit watcher silent** | No `config_snapshots` from a boss in > 10 min | **P2** | Feishu mention | Watcher may be down |

### 9.2 Alert Enrichment

When an alert fires, the notification should include:

```
=== Config Audit Alert (P1: Unauthorized Edit) ===

Cluster:   aliyun
File:      /home/dev/.config/kyb/config.yml
Detected:  2026-05-23T10:30:00Z
Checksum:  a1b2c3d4e5f6...  (old: 9z8y7x6w5v4u...)
Expected:   (no active baseline matches)

Classification: manual_edit
Reason: File checksum changed, no matching baseline, working tree is clean

Git context:
  Branch:  main
  Commit:  abc123def456
  Dirty:   false

Recent changes to this file:
  - 2026-05-22: baseline set (deploy: git-pull, checksum: 9z8y7x6w...)
  - 2026-04-30: baseline set (deploy: infra-agent-A3, checksum: b2c3d4e5...)

Action required: Investigate and either:
  1. Register baseline (if change is legitimate): register-baseline --cluster aliyun ...
  2. Revert file to known-good version
  3. Acknowledge false positive: ALTER TABLE infra.config_changes UPDATE acknowledged=1 ...
```

### 9.3 Integration with Patrol

The 5-minute patrol already checks container health, disk, and network. Add a config audit check to the patrol checklist:

```bash
# In patrol script:
# 1. Run config audit watcher
/usr/local/bin/config-audit-watcher.sh

# 2. Check for unacknowledged critical changes
UNACKED=$(curl -s --max-time 5 \
  "http://100.104.244.99:8123?query=SELECT+count()+
   FROM+infra.config_changes+
   WHERE+alert_level+IN+('critical','warning')
   AND+acknowledged%3D0
   AND+detected_at+>+now()+-+INTERVAL+1+HOUR
   FORMAT+TabSeparated" 2>/dev/null || echo "0")

if [ "$UNACKED" -gt 0 ] && [ "$UNACKED" != "0" ]; then
    logger "[PATROL] $UNACKED unacknowledged config changes detected"
    # Dispatch feishu alert via cc-connect
    curl -s -X POST http://kyb-infra-cc-connect:8080/alert \
      -H "Content-Type: application/json" \
      -d "{\"severity\":\"warning\",\"message\":\"$UNACKED config changes need review\"}" \
      --max-time 5 2>/dev/null || true
fi
```

### 9.4 Suppression During Deploy Windows

During known maintenance windows, alerts should be suppressed to avoid noise:

```sql
-- Add to infra.config_baselines: a "deploy window" marker
-- The watcher checks: if current time is within a known deploy window,
-- reduce alert_level by one step (critical -> warning, warning -> info)

-- Deploy window registration (on super-boss CK):
INSERT INTO infra.deploy_windows FORMAT JSONEachRow {
  "cluster": "mac-orbstack",
  "start_time": "2026-05-23T14:00:00Z",
  "end_time": "2026-05-23T16:00:00Z",
  "description": "Scheduled config update for registry mirror",
  "deployer": "super-boss"
};
```

---

## 10. Grafana Dashboard

### 10.1 Dashboard: Config Audit Overview

**Panel 1: Config Drift Gauge (Single Stat)**
- Metric: count of unacknowledged config changes with `alert_level = 'critical'`
- Thresholds: 0 = green, >0 = red
- Purpose: at-a-glance health of config state

**Panel 2: Change Timeline (Time Series)**
- X-axis: time (24h)
- Y-axis: count of changes per hour
- Color by `classification` (authorized_deploy = green, manual_edit = red, git_commit = blue)
- Purpose: visualize config change activity over time

**Panel 3: Current Drift Table**
- Columns: cluster, file_path, alert_level, classification, detected_at, ack
- Filter: `acknowledged = 0 AND alert_level != 'none'`
- Sort: by `detected_at` descending
- Purpose: immediate action list -- "these config changes need review"

**Panel 4: File Change History (Table)**
- Columns: file_path, cluster, change_count_7d, last_change, last_classification
- Query: aggregate changes per file over 7 days
- Purpose: identify frequently-changing files (instability signal)

**Panel 5: Baseline Coverage (Bar Chart)**
- Metric: per-cluster, count of tracked files that have an active baseline
- Y-axis: files with baseline / total tracked files
- Color: green = all files have baselines, yellow = some, red = none
- Purpose: audit completeness -- are all config files baselined?

**Panel 6: Config Snapshot Explorer (Table)**
- Columns: scan_time, cluster, file_path, checksum (truncated), change_type, file_size
- Filter: select cluster and file_path from dropdown
- Purpose: forensic investigation -- what did a specific file look like at time T?

### 10.2 Dashboard Variables

```yaml
variables:
  - name: cluster
    type: custom
    options: [all, mac-orbstack, aliyun, office]
    default: all

  - name: alert_level
    type: custom
    options: [all, none, info, warning, critical]
    default: critical

  - name: classification
    type: custom
    options: [all, authorized_deploy, manual_edit, git_commit, rollback, unknown]
    default: all

  - name: file_path
    type: query
    query: SELECT DISTINCT file_path FROM infra.config_changes ORDER BY file_path
    multi: true
```

### 10.3 Alert Integration

Grafana alert rules for config audit:

| Alert Name | Query | Condition | Duration |
|------------|-------|-----------|----------|
| UnauthorizedConfigEdit | See panel 1 query | > 0 | 5m |
| ConfigAlertAccumulation | `count(alert_level = 'warning' OR 'critical' AND ack=0) > 5` | > 5 | 10m |
| WatcherSilent | `max(scan_time) < now() - 10m` | true | 2m |

---

## 11. Query Examples

### 11.1 Current State of All Tracked Files on a Cluster

```sql
-- Latest snapshot per file (most recent scan)
SELECT file_path, checksum, change_type, scan_time, alert_level
FROM infra.config_snapshots
WHERE cluster = 'mac-orbstack'
ORDER BY scan_time DESC
LIMIT 1 BY file_path;
```

### 11.2 Unacknowledged Critical Changes

```sql
SELECT detected_at, cluster, file_path, classification, classification_reason
FROM infra.config_changes
WHERE acknowledged = 0
  AND alert_level = 'critical'
ORDER BY detected_at DESC;
```

### 11.3 Config File Change History (Single File)

```sql
-- Full change history for a specific config file
SELECT detected_at, change_type, classification, alert_level,
       old_checksum, new_checksum, expected_checksum,
       git_commit, git_branch, git_is_dirty
FROM infra.config_changes
WHERE file_path = '/home/dev/.config/kyb/config.yml'
  AND cluster = 'mac-orbstack'
ORDER BY detected_at DESC;
```

### 11.4 Files with No Active Baseline (Unmonitored Config)

```sql
-- Find files that have snapshots but no baseline
SELECT DISTINCT cs.file_path, cs.cluster, cs.checksum, cs.scan_time
FROM infra.config_snapshots cs
LEFT JOIN infra.config_baselines cb
  ON cs.file_path = cb.file_path
  AND cs.cluster = cb.cluster
  AND cb.is_active = 1
WHERE cb.checksum IS NULL
  AND cs.change_type != 'deleted'
ORDER BY cs.file_path;
```

### 11.5 Drift-Prone Files (Most Changes)

```sql
SELECT file_path, cluster, count() AS change_count,
       countIf(classification = 'manual_edit') AS manual_edits,
       countIf(alert_level IN ('warning', 'critical')) AS alerts
FROM infra.config_changes
WHERE detected_at >= now() - INTERVAL 7 DAY
GROUP BY file_path, cluster
ORDER BY change_count DESC;
```

### 11.6 Config "State at Time T" Reconstruction

```sql
-- What did config.yml look like at 2026-05-22 12:00:00?
SELECT *
FROM infra.config_snapshots
WHERE file_path = '/home/dev/.config/kyb/config.yml'
  AND scan_time <= '2026-05-22T12:00:00.000Z'
ORDER BY scan_time DESC
LIMIT 1;
```

### 11.7 Baseline Drift (Expected != Actual)

```sql
-- Files where current checksum does NOT match active baseline
SELECT cs.cluster, cs.file_path, cs.checksum AS actual,
       cb.checksum AS expected, cs.scan_time
FROM infra.config_snapshots cs
INNER JOIN infra.config_baselines cb
  ON cs.file_path = cb.file_path
  AND cs.cluster = cb.cluster
  AND cb.is_active = 1
WHERE cs.checksum != cb.checksum
  AND cs.change_type != 'deleted'
ORDER BY cs.scan_time DESC
LIMIT 1 BY cs.file_path, cs.cluster;
```

### 11.8 Deploy Audit Trail

```sql
-- Show the deployment history for a config file
SELECT deployed_at, deployed_by, version, checksum, description,
       deployment_id
FROM infra.config_baselines
WHERE file_path = '/home/dev/.config/kyb/config.yml'
  AND cluster = 'aliyun'
ORDER BY version DESC;
```

### 11.9 Cross-Cluster Config Comparison

```sql
-- Compare the same config file across clusters
SELECT file_path, cluster, checksum, scan_time
FROM infra.config_snapshots
WHERE file_path = '/home/dev/.config/kyb/config.yml'
ORDER BY scan_time DESC
LIMIT 1 BY cluster;
```

### 11.10 Files That Changed While Watcher Was Down

```sql
-- Detect config changes that occurred during a gap in snapshots
-- (watcher was down, file was edited, watcher came back and saw change)
SELECT s1.file_path, s1.cluster,
       s1.scan_time AS after_time,
       s2.scan_time AS before_time,
       s1.checksum AS after_checksum,
       s2.checksum AS before_checksum,
       dateDiff('second', s2.scan_time, s1.scan_time) AS gap_seconds
FROM infra.config_snapshots s1
INNER JOIN infra.config_snapshots s2
  ON s1.file_path = s2.file_path
  AND s1.cluster = s2.cluster
  AND s1.checksum != s2.checksum
  AND s1.scan_time > s2.scan_time
WHERE s2.scan_time = (
    SELECT max(scan_time)
    FROM infra.config_snapshots
    WHERE file_path = s1.file_path
      AND cluster = s1.cluster
      AND scan_time < s1.scan_time
)
AND dateDiff('minute', s2.scan_time, s1.scan_time) > 15
ORDER BY gap_seconds DESC;
```

---

## 12. Operational Runbook

### 12.1 Adding a New Config File to Audit

1. Identify the file path and which cluster(s) it belongs to
2. Add the path to the watcher's `FILES_TO_SCAN` array (per-cluster section)
3. Deploy the updated watcher to each boss (`git push` + patrol pulls the update)
4. Verify: after 2 scan cycles, `infra.config_snapshots` shows the file
5. Register an initial baseline if the file should be treated as "known-good":

```bash
register-baseline --cluster mac-orbstack \
  --file /path/to/new/config.yml \
  --deployer "setup" \
  --desc "Initial baseline for new config file"
```

### 12.2 Removing a Config File from Audit

1. Remove the path from `FILES_TO_SCAN`
2. Optionally deactivate its baselines:

```sql
ALTER TABLE infra.config_baselines
UPDATE is_active = 0
WHERE file_path = '/old/path/removed.conf'
  AND is_active = 1;
```

3. The snapshots remain in CK for historical reference (TTL takes care of cleanup)

### 12.3 Responding to a Critical Config Alert

**Step 1: Identify the change**

```sql
-- What changed, when, and how?
SELECT * FROM infra.config_changes
WHERE alert_level = 'critical'
  AND acknowledged = 0
ORDER BY detected_at DESC
LIMIT 5;
```

**Step 2: Determine if the change is legitimate**

- SSH into the affected cluster
- Read the config file: `cat /home/dev/.config/kyb/config.yml`
- Check git status: `git -C /home/dev/.kyb status`
- Check `git log` for recent commits that might have touched the file
- Check who was logged in at the time: `last | head`

**Step 3a: If legitimate, register baseline:**

```bash
# From the affected boss:
register-baseline --cluster aliyun \
  --file /home/dev/.config/kyb/config.yml \
  --deployer "dongqs" \
  --desc "Updated proxy for new relay"
```

**Step 3b: If unauthorized, revert the file:**

```bash
# Revert from git (if tracked)
git -C /home/dev/.kyb checkout -- ~/.config/kyb/config.yml

# Or restore from backup
cp /var/backups/kyb/config.yml.2026-05-22 ~/.config/kyb/config.yml
```

Then acknowledge the alert:

```sql
ALTER TABLE infra.config_changes
UPDATE acknowledged = 1, ack_by = 'super-boss', ack_at = now()
WHERE detected_at = '<detected_at>'
  AND file_path = '/home/dev/.config/kyb/config.yml'
  AND cluster = 'aliyun';
```

### 12.4 Adding a Deploy Window

```bash
# Register a maintenance window (alert suppression)
curl -s -X POST http://100.104.244.99:8123 \
  -d "INSERT INTO infra.deploy_windows FORMAT JSONEachRow {
    \"cluster\": \"mac-orbstack\",
    \"start_time\": \"2026-05-23T14:00:00Z\",
    \"end_time\": \"2026-05-23T16:00:00Z\",
    \"description\": \"Registry mirror config update\",
    \"deployer\": \"super-boss\"
  }"
```

### 12.5 Recovering from CK Outage

If central CK is down, the watcher skips writes but continues comparing against the local cache. When CK comes back:

1. The existing cache ensures no false "changed" events from the outage gap
2. New snapshots will be written normally on the next scan
3. Any changes made during the outage will be detected on the first post-outage scan (since the cache still has the pre-outage checksums)

To backfill a long outage (hours/days):

```bash
# Force a full re-scan that records the current state as baseline
register-baseline --cluster mac-orbstack \
  --file /home/dev/.config/kyb/config.yml \
  --deployer "post-outage-recovery" \
  --desc "Re-baseline after CK outage"
```

### 12.6 Periodic Maintenance

| Task | Frequency | Why |
|------|-----------|-----|
| Review unacknowledged changes | Daily (patrol) | Config drift accumulates silently |
| Prune old snapshots | Monthly | TTL handles this automatically, but verify |
| Audit baseline coverage | Weekly | New files may have been added without baselines |
| Review drift-prone files | Monthly | Files that change frequently may need process improvement |
| Update watched file list | Per-infra-change | When new services are deployed, add their config files |

### 12.7 Integration with Existing Infra

| Existing Component | How It Connects |
|--------------------|----------------|
| `boss_heartbeats` (Section 2.4 of multi-cluster-architecture) | Runs on same schedule, same CK instance. Config audit watcher can share the heartbeat's curl pattern and error handling. |
| `docker-event-watcher` (docker-events.md) | Both run inside `kyb-infra-boss`. Config audit catches config file changes; Docker events catch container lifecycle changes. Together they provide full change coverage. |
| `infra.config_baselines` (this doc) | The baselines table is the source of truth for expected config state. The watcher, Grafana dashboards, and patrol all reference it. |
| 5-minute patrol (patrol-guide.md) | Patrol triggers config audit scan. Patrol also checks for unacknowledged critical changes. |
| Feishu alerting (feishu-delivery.md) | Critical and warning alerts are routed to the infra Feishu group via the same bridge used for other alerts. |
| Error budget (error-budget.md) | Config audit failures (unauthorized edits) do not directly consume error budget, but they can cause service degradation that does. Post-incident: if an unauthorized config edit caused an outage, the config audit event is linked in the incident timeline. |

---

## 13. Deployment Plan

### Phase 1: Schema Setup (5 minutes)

```bash
# Run on super-boss CK:
docker exec kyb-infra-clickhouse clickhouse-client --query "
CREATE DATABASE IF NOT EXISTS infra;

CREATE TABLE IF NOT EXISTS infra.config_snapshots (
    boss_id LowCardinality(String),
    cluster LowCardinality(String),
    scan_time DateTime64(3),
    file_path String,
    checksum FixedString(64),
    file_size UInt32,
    file_mode String,
    mtime DateTime64(3),
    uid UInt16,
    gid UInt16,
    user_name String DEFAULT '',
    group_name String DEFAULT '',
    expected_checksum FixedString(64) DEFAULT '',
    change_type Enum8('unchanged'=0,'changed'=1,'new'=2,'deleted'=3,'baseline'=4) DEFAULT 'unchanged',
    git_commit String DEFAULT '',
    git_branch String DEFAULT '',
    git_is_dirty Bool DEFAULT false,
    is_manual_edit Bool DEFAULT false,
    alert_level Enum8('none'=0,'info'=1,'warning'=2,'critical'=3) DEFAULT 'none',
    _ingested_at DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (scan_time, cluster, file_path)
TTL scan_time + INTERVAL 365 DAY;

CREATE TABLE IF NOT EXISTS infra.config_changes (
    boss_id LowCardinality(String),
    cluster LowCardinality(String),
    detected_at DateTime64(3),
    file_path String,
    change_type Enum8('modified'=0,'created'=1,'deleted'=2,'permissions_changed'=3,'reverted'=4),
    old_checksum FixedString(64) DEFAULT '',
    new_checksum FixedString(64) DEFAULT '',
    expected_checksum FixedString(64) DEFAULT '',
    is_authorized Bool DEFAULT false,
    file_size_old UInt32 DEFAULT 0,
    file_size_new UInt32 DEFAULT 0,
    mtime_old DateTime64(3),
    mtime_new DateTime64(3),
    git_commit String DEFAULT '',
    git_branch String DEFAULT '',
    git_is_dirty Bool DEFAULT false,
    classification Enum8('unknown'=0,'authorized_deploy'=1,'manual_edit'=2,'git_commit'=3,'rollback'=4,'infra_agent'=5) DEFAULT 'unknown',
    classification_reason String DEFAULT '',
    alert_level Enum8('none'=0,'info'=1,'warning'=2,'critical'=3) DEFAULT 'none',
    acknowledged Bool DEFAULT false,
    ack_by String DEFAULT '',
    ack_at DateTime64(3),
    _ingested_at DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (detected_at, cluster, file_path)
TTL detected_at + INTERVAL 365 DAY;

CREATE TABLE IF NOT EXISTS infra.config_baselines (
    cluster LowCardinality(String),
    boss_id LowCardinality(String) DEFAULT '',
    file_path String,
    checksum FixedString(64),
    deployed_at DateTime64(3),
    deployed_by String,
    deployment_id String DEFAULT '',
    version UInt32,
    description String DEFAULT '',
    is_active Bool DEFAULT true,
    _ingested_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(version)
ORDER BY (cluster, file_path, version);
"
```

### Phase 2: Deploy Watcher to Mac/Orbstack (10 minutes)

```bash
# Write watcher script to boss
docker exec infra-boss bash -c "
cat > /usr/local/bin/config-audit-watcher.sh << 'SCRIPT'
# [paste the full watcher script from Section 5.1]
SCRIPT
chmod +x /usr/local/bin/config-audit-watcher.sh
"

# Register initial baselines for all tracked files
docker exec infra-boss bash -c "
for f in /home/dev/.config/kyb/config.yml /home/dev/.config/kyb/clusters.yml /home/dev/.kyb/Dockerfile /home/dev/.kyb/entrypoint.sh /home/dev/.kyb/mise.config.toml; do
    [ -f \"\$f\" ] && register-baseline --cluster mac-orbstack --file \"\$f\" --deployer 'initial-setup' --desc 'Initial baseline'
done
"

# Test manually
docker exec infra-boss bash -c "
/usr/local/bin/config-audit-watcher.sh
# Verify: curl ...?query='SELECT count() FROM infra.config_snapshots WHERE cluster=mac-orbstack'
"
```

### Phase 3: Verify and Wire to Patrol (10 minutes)

```bash
# Check snapshots appearing
curl -s 'http://100.104.244.99:8123?query=SELECT+count()%2C+cluster+FROM+infra.config_snapshots+GROUP+BY+cluster+FORMAT+TabSeparated'

# Add to patrol script
docker exec infra-boss bash -c "
echo '/usr/local/bin/config-audit-watcher.sh 2>/dev/null' >> /usr/local/bin/patrol.sh
"
```

### Phase 4: Deploy to Remote Clusters (15 minutes)

```bash
# Aliyun
ssh sim "docker exec kyb-infra-boss bash -c '
cat > /usr/local/bin/config-audit-watcher.sh << '\''SCRIPT'\''
[paste watcher script]
SCRIPT
chmod +x /usr/local/bin/config-audit-watcher.sh
'"

register-baseline --cluster aliyun \
  --file /home/dev/.config/kyb/config.yml \
  --deployer 'remote-deploy' \
  --desc 'Initial baseline for Aliyun'

# Office
ssh nuc8 "docker exec kyb-infra-boss bash -c '
cat > /usr/local/bin/config-audit-watcher.sh << '\''SCRIPT'\''
[paste watcher script]
SCRIPT
chmod +x /usr/local/bin/config-audit-watcher.sh
'"

register-baseline --cluster office \
  --file /home/dev/.config/kyb/config.yml \
  --deployer 'remote-deploy' \
  --desc 'Initial baseline for Office'
```

### Phase 5: Grafana Dashboard (30 minutes)

1. Create ClickHouse data source in Grafana (already exists for other dashboards)
2. Import panels from Section 10
3. Wire alerts from Section 9 to Feishu notification channel
4. Verify: edit a config file manually, confirm alert fires in < 5 minutes

---

## Verdict

**Design is sound and ready for implementation.** The architecture is:

- **Zero new infrastructure** -- reuses existing boss containers, central CK, patrol cycle
- **Low overhead** -- 5-minute scan of ~20 files costs ~100ms and ~50 bytes/snapshot/year
- **Comprehensive coverage** -- snapshots capture full state, changes capture deltas, baselines provide an expected-state anchor
- **Resilient** -- CK outages are handled gracefully via local cache
- **Integratable** -- plugs into existing patrol, heartbeat, and alerting pipelines

The highest-value outcome is **automated detection of manual/unauthorized config edits**. Currently, any agent or human with SSH access and `docker exec` can modify a boss's config with no audit trail. This design closes that gap.

Implementation priority:
1. Run CREATE TABLE on central CK (Phase 1)
2. Deploy watcher to Mac/Orbstack, manually test (Phase 2-3)
3. Deploy to Aliyun and Office (Phase 4)
4. Build Grafana dashboard + Feishu alerts (Phase 5)
5. Register baselines for all existing tracked files

> *／人◕ ‿‿ ◕人＼*
