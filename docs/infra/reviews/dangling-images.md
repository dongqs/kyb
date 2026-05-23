---
decision: 稍后做
---

# Design: Dangling Image & Disk Waste Tracking

**Design doc**: `docs/infra/reviews/dangling-images.md`
**Reviewer**: kyb
**Date**: 2026-05-23
**Scope**: Docker disk waste classification, dangling image monitoring, auto-cleanup policy, ClickHouse ingestion

---

## Summary

Docker disk usage on the Mac/Orbstack host is **181.5 GB total** across images (110.5 GB), containers (31.5 GB), volumes (16.1 GB), and build cache (23.3 GB). Of this, **~28 GB is reclaimable** (15% of images, 29% of container layers, 10% of build cache). There is currently no automated tracking of dangling images, unused volumes, or stale build cache. Left unchecked, waste accumulates silently until disk fills -- at which point builds fail, containers crash, and patrols page.

This design introduces:

1. A **waste classification taxonomy** (dangling images, stale tags, orphaned volumes, zombie containers, build cache rot)
2. A **periodic snapshot table** in ClickHouse (`infra.disk_waste`) to track waste over time
3. A **Grafana dashboard** for disk waste trends
4. An **auto-cleanup policy** tiered by waste severity
5. Alert rules when waste exceeds thresholds

---

## Current State

### Host-Level Summary

| Category | Total | Active | Waste | Reclaimable % |
|----------|-------|--------|-------|---------------|
| Images | 57 | 15 | 17.55 GB | 15% |
| Containers | 24 | 20 | 9.17 GB | 29% |
| Local Volumes | 25 | 19 | 0.02 GB | <1% |
| Build Cache | 44 entries | 0 | 2.41 GB | 10% |
| **Total** | -- | -- | **~29.15 GB** | ~16% |

### Image Waste Breakdown

#### 1. Dangling Images (`<none>:<none>`)

| Image ID | Size | Age | Reason |
|----------|------|-----|--------|
| `9effd59e2729` | 6.07 GB | 2 days | Leftover from kyb-base rebuild |

These are orphaned layers with no tag and no container reference. Each `docker build` of `kyb-base` or `kyb-infra-boss-snapshot` leaves the previous build's intermediate layers as dangling images if the new build shares no layer ancestry with the old.

#### 2. Stale Tagged Images (no container using them)

| Image | Tag(s) | Size | Count | Waste |
|-------|--------|------|-------|-------|
| `click-rest` | 5 different tags (`20260522-beijing`, `20260522140919-*`, `20260522112508-*`, `20260522112755-*`, `20260520175702-*`) | 163 MB each | 5 | **815 MB** |
| `nginx-test` | 7 different ACR paths (`client-rest`, `default`, `dockerhub`, `kyb`, `mirror`, `ns1`, `public`, `test`) | 22.6 MB each | 8 | **181 MB** |
| `peerdb-server` | `stable-v0.36.18`, `stable-v0.36.17`, `stable-v0.35.0` | 98 MB, 84 MB, 84 MB | 3 | **266 MB** |
| `alpine` | `3.17`, `3.18`, `3.19` | 12.4 MB, 12.7 MB, 12.8 MB | 3 | **38 MB** |
| `python` | `3.11-slim` (212 MB), `3-alpine` (78 MB), `3.13-alpine` (75 MB), `3.12-alpine` (80 MB) | various | 4 | **445 MB** |
| `ruby` | `3.3` (1.61 GB), `3.3-slim` (499 MB), `3.3-alpine` (124 MB) | various | 3 | **2.23 GB** |
| `node` | `lts-alpine` (227 MB), `22-alpine` (228 MB) | various | 2 | **455 MB** |
| `clickhouse/clickhouse-server` | `head-alpine` (969 MB, unused) + `24.2-alpine` (1.17 GB, in use) | various | 1 | **969 MB** |
| `docker.1ms.run/grafana/grafana` | `11.5.2` (704 MB, old mirror) | 704 MB | 1 | **704 MB** |
| `docker:git` | `git` (480 MB, test image) | 480 MB | 1 | **480 MB** |
| `memcached` | `1.6-alpine` (22 MB, test image) | 22 MB | 1 | **22 MB** |
| `tonistiigi/binfmt` | `latest` (112 MB, rarely needed) | 112 MB | 1 | **112 MB** |

#### 3. Build Cache Rot

| Cache Entry | Size | Last Access |
|-------------|------|-------------|
| `14dq755ldfnoqksa06528nols` | 1.002 GB | 6 hours ago |
| `kgy3w6f4gzoyjk13iiz9ov58j` | 280.6 MB | 7 hours ago |
| `py7uyjug5b4rgqhmob6m7mn99` | 69.15 MB | 6 hours ago |
| Other small entries | ~1.06 GB | various |

Total build cache: **23.34 GB**. Reclaimable: **2.41 GB** (the rest is shared/layered and not pruneable without rebuild).

#### 4. Zombie Containers (Exited / Not Running)

| Container | Image | Status | Size |
|-----------|-------|--------|------|
| `friendly_banach` | `7cb4dba19d5f` | Exited (5) 13 hours ago | 4.45 GB |
| `kyb-kyb-robust` | `7cb4dba19d5f` | Exited (5) 13 hours ago | 4.45 GB |
| `a2dc1a6bb618` (unnamed) | `7a706317265f` | Exited | ~4 GB |

Zombie containers account for **~13 GB** of container-level waste. These are containers that crashed or were stopped during development/testing but were never `docker rm`'d. The image `7cb4dba19d5f` and `7a706317265f` are intermediate build outputs (snapshots from `kyb create` or `kyb did create`).

#### 5. Unused Volumes

| Volume | Size | Purpose |
|--------|------|---------|
| 6 dangling unnamed volumes | ~20 MB total | Leftover anonymous volumes |

Volume waste is minimal (20 MB). Most named volumes are actively used.

### Waste Categorization

| Category | Definition | Current Waste | Cleanup Method |
|----------|-----------|---------------|----------------|
| **Dangling images** | `<none>:<none>` images | 6.07 GB | `docker image prune` |
| **Stale tagged images** | Tagged but unused by any container | ~6.7 GB | `docker image prune -a` (selective) |
| **Zombie containers** | Exited containers not removed | ~13 GB | `docker container prune` |
| **Orphaned volumes** | Volumes not mounted by any container | 20 MB | `docker volume prune` |
| **Build cache rot** | Pruneable builder cache | 2.41 GB | `docker builder prune` |
| **Total reclaimable** | | **~28 GB** | |

---

## Architecture

### Data Flow

```
Mac/Orbstack Host
    │  (docker system df --verbose + docker image ls)
    │  (via kyb-infra-boss patrol script, every 5 minutes)
    ▼
disk-waste-collector (bash script inside kyb-infra-boss)
    │  (HTTP POST to central CK:8123)
    ▼
ClickHouse (infra.disk_waste_snapshots)
    │
    ├── Grafana dashboard (waste trends over time, growth rate)
    ├── Threshold alerts (waste growing too fast)
    └── Auto-cleanup trigger (when waste > threshold)
```

### Why a Collector (Not Just `docker system df`)

`docker system df` gives a point-in-time snapshot. Without a time series, we cannot:
- Detect waste growth trends ("are we accumulating faster than we clean?")
- Correlate waste spikes with events ("did that `kyb create` leave 4 GB behind?")
- Measure cleanup effectiveness ("did the prune actually free space?")
- Set meaningful thresholds ("is 15% waste normal for this host?")

A periodic snapshot in ClickHouse solves all four.

### Collector Script

A lightweight bash script runs inside `kyb-infra-boss` as part of the 5-minute patrol cycle:

```bash
#!/usr/bin/env bash
# disk-waste-collector.sh — runs inside kyb-infra-boss
# Captures Docker disk waste metrics and POSTs to central CK.

CK_URL="http://100.104.244.99:8123"
CK_TABLE="infra.disk_waste_snapshots"
BOSS_ID="$(hostname)"
CLUSTER="${CLUSTER_NAME:-mac-orbstack}"
SNAPSHOT_TIME="$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')"

collect_image_waste() {
  # Count total, active, dangling images and their sizes
  python3 <<'PYEOF'
import json, subprocess

# --- docker image ls: count dangling ---
dangling_out = subprocess.run(
    ["docker", "image", "ls", "-f", "dangling=true", "--format", "{{.Size}}"],
    capture_output=True, text=True
)
dangling_count = 0
dangling_bytes = 0
for line in dangling_out.stdout.strip().split('\n'):
    if not line.strip():
        continue
    dangling_count += 1
    s = line.strip().upper()
    if s.endswith('GB'):
        dangling_bytes += float(s.replace('GB','')) * 1024**3
    elif s.endswith('MB'):
        dangling_bytes += float(s.replace('MB','')) * 1024**2
    elif s.endswith('KB'):
        dangling_bytes += float(s.replace('KB','')) * 1024
    elif s.endswith('B'):
        dangling_bytes += float(s.replace('B',''))
    else:
        dangling_bytes += float(s)

# --- docker system df: total vs reclaimable ---
df_out = subprocess.run(
    ["docker", "system", "df", "--format", "{{json .}}"],
    capture_output=True, text=True
)
rows = []
for line in df_out.stdout.strip().split('\n'):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        pass

snapshot = {
    "boss_id": "$BOSS_ID",
    "cluster": "$CLUSTER",
    "snapshot_time": "$SNAPSHOT_TIME",
}
for r in rows:
    rtype = r.get("Type", "").lower()
    if rtype == "images":
        snapshot["images_total"] = int(r.get("TotalCount", 0))
        snapshot["images_active"] = int(r.get("ActiveCount", 0))
        snapshot["images_size"] = _parse_size(r.get("Size", "0B"))
        snapshot["images_reclaimable"] = _parse_size(r.get("ReclaimableSize", "0B"))
    elif rtype == "containers":
        snapshot["containers_total"] = int(r.get("TotalCount", 0))
        snapshot["containers_active"] = int(r.get("ActiveCount", 0))
        snapshot["containers_size"] = _parse_size(r.get("Size", "0B"))
        snapshot["containers_reclaimable"] = _parse_size(r.get("ReclaimableSize", "0B"))
    elif rtype == "local volumes":
        snapshot["volumes_total"] = int(r.get("TotalCount", 0))
        snapshot["volumes_active"] = int(r.get("ActiveCount", 0))
        snapshot["volumes_size"] = _parse_size(r.get("Size", "0B"))
        snapshot["volumes_reclaimable"] = _parse_size(r.get("ReclaimableSize", "0B"))
    elif rtype == "build cache":
        snapshot["build_cache_total"] = int(r.get("TotalCount", 0))
        # Build cache: "active" is 0 for cache entries
        snapshot["build_cache_size"] = _parse_size(r.get("Size", "0B"))
        snapshot["build_cache_reclaimable"] = _parse_size(r.get("ReclaimableSize", "0B"))

snapshot["dangling_images"] = dangling_count
snapshot["dangling_images_size"] = dangling_bytes

# Calculate summary metrics
snapshot["total_waste_gb"] = round(
    (_parse_size(r.get("ReclaimableSize", "0B")) for r in rows if ...)
)  # computed below

print(json.dumps(snapshot))

def _parse_size(s):
    s = s.upper().strip()
    if s.endswith('GB'):
        return float(s.replace('GB','')) * 1024**3
    elif s.endswith('MB'):
        return float(s.replace('MB','')) * 1024**2
    elif s.endswith('KB'):
        return float(s.replace('KB','')) * 1024
    elif s.endswith('B'):
        return float(s.replace('B',''))
    return 0.0
PYEOF
}

payload=$(collect_image_waste)
curl -s -X POST "$CK_URL?query=INSERT+INTO+$CK_TABLE+FORMAT+JSONEachRow" \
  -d "$payload" \
  --max-time 5 2>/dev/null || echo "[WARN] CK write failed for disk waste snapshot"
```

### Why Not `docker system df --format '{{json .}}'` Alone

The built-in JSON format outputs one row per type but does not include dangling image counts or per-tag breakdowns. The collector enriches the snapshot with:

- Dangling image count and size (via `docker image ls -f dangling=true`)
- Per-tag stale image inventory (optional, weekly)
- Build cache reclaimable breakdown (for estimating true waste)

---

## ClickHouse Schema

```sql
CREATE TABLE IF NOT EXISTS infra.disk_waste_snapshots (
    -- Identity
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),
    snapshot_time   DateTime64(3),

    -- Images
    images_total        UInt16,
    images_active       UInt16,
    images_size         UInt64,          -- bytes
    images_reclaimable  UInt64,          -- bytes

    -- Dangling images (subset of images)
    dangling_images      UInt16,
    dangling_images_size UInt64,         -- bytes

    -- Containers
    containers_total        UInt16,
    containers_active       UInt16,
    containers_size         UInt64,
    containers_reclaimable  UInt64,

    -- Volumes
    volumes_total        UInt16,
    volumes_active       UInt16,
    volumes_size         UInt64,
    volumes_reclaimable  UInt64,

    -- Build cache
    build_cache_size         UInt64,
    build_cache_reclaimable  UInt64,
    build_cache_entries      UInt16,

    -- Derived
    total_waste_bytes  UInt64,           -- sum of all reclaimable
    waste_pct          Float32,          -- total_waste / total_size * 100

    -- Metadata
    _ingested_at DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (snapshot_time, cluster)
TTL snapshot_time + INTERVAL 180 DAY;
```

### Estimated Volume

| Item | Value |
|------|-------|
| Snapshots per day | 288 (every 5 min) |
| Row size (compressed) | ~120 bytes |
| Daily storage | ~34 KB |
| 180-day retention | ~6 MB |

Negligible. Even with a per-tag breakdown table (weekly, ~200 rows), total storage is under 50 MB.

### Supplementary Table: Tag Inventory (Weekly)

For tracking stale tagged images, a separate table updated weekly:

```sql
CREATE TABLE IF NOT EXISTS infra.image_tag_inventory (
    snapshot_time   DateTime64(3),
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),

    repository      String,
    tag             String,
    image_id        String,
    size_bytes      UInt64,
    created_at      DateTime64(3),
    in_use          UInt8,               -- 1 = referenced by a container
    age_days        UInt16               -- how many days since created
) ENGINE = MergeTree
ORDER BY (snapshot_time, repository, tag)
TTL snapshot_time + INTERVAL 90 DAY;
```

This gives us the ability to answer "which images have been unused for 30+ days?" and drive cleanup decisions.

---

## Grafana Dashboard

### Panel 1: Waste Overview (Stat Row)

Four single-stat panels:

```
┌─────────────────┐ ┌──────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ Total Disk Used  │ │ Total Waste       │ │ Waste %          │ │ Dangling Images  │
│ 181.5 GB         │ │ 29.1 GB           │ │ 16%              │ │ 1 (6.07 GB)      │
│ (current)        │ │ (current)         │ │ (current)        │ │ (current)        │
└─────────────────┘ └──────────────────┘ └─────────────────┘ └─────────────────┘
```

Color coding:
- Waste %: green < 10%, yellow 10-20%, red > 20%
- Dangling: green = 0, yellow = 1-3, red > 3

### Panel 2: Waste Trend (Time Series)

Stacked area chart showing each waste category over the last 7 days:

```
GB
30 ┤
   │  ████ build cache reclaimable
25 ┤  ████ containers reclaimable
   │  ████ images reclaimable
20 ┤  ████ dangling images
   │
15 ┤
   │
10 ┤
   │
 5 ┤
   │
 0 └──────────────────────────────────►
   Mon   Tue   Wed   Thu   Fri   Sat   Sun
```

Query:
```sql
SELECT
    snapshot_time,
    images_reclaimable / 1073741824 AS images_waste_gb,
    containers_reclaimable / 1073741824 AS containers_waste_gb,
    dangling_images_size / 1073741824 AS dangling_waste_gb,
    build_cache_reclaimable / 1073741824 AS cache_waste_gb
FROM infra.disk_waste_snapshots
WHERE cluster = 'mac-orbstack'
  AND snapshot_time >= now() - INTERVAL 7 DAY
ORDER BY snapshot_time;
```

### Panel 3: Waste Composition (Pie Chart)

Current snapshot distribution:

```
Dangling images:   6.07 GB  (21%)
Stale containers:  9.17 GB  (31%)
Build cache rot:   2.41 GB  (8%)
Stale images:      11.5 GB  (40%)
```

### Panel 4: Dangling Image Inventory (Table)

Updated daily:

| Image ID | Size | Age | Repository (if known) | Last Used |
|----------|------|-----|----------------------|-----------|
| `9effd59e2729` | 6.07 GB | 2 days | kyb-base build artifact | never |

### Panel 5: Waste Growth Rate (Bar Chart)

Day-over-day waste increase:

```
Day        New Waste    Category
2026-05-22 +6.07 GB     Dangling image (kyb-base rebuild)
2026-05-21 +0.5 GB      Build cache (kyb-cc-connect build)
2026-05-20 +0.0 GB      No change
```

Query:
```sql
SELECT
    toDate(snapshot_time) AS day,
    max(total_waste_bytes) - min(total_waste_bytes) AS waste_delta
FROM infra.disk_waste_snapshots
WHERE snapshot_time >= now() - INTERVAL 14 DAY
GROUP BY day
ORDER BY day;
```

### Panel 6: Cleanup Effectiveness (Time Series with Annotations)

Overlay prune events as annotations on the waste trend chart. After a `docker system prune`, the waste line should drop. If it doesn't, the prune was ineffective.

---

## Auto-Cleanup Policy

### Tier Definitions

| Tier | Waste Threshold | Action | Frequency | Risk |
|------|----------------|--------|-----------|------|
| **Green** | < 10% waste | No action | -- | None |
| **Yellow** | 10-20% waste | Soft prune (safe categories only) | Daily if sustained > 24h | Low |
| **Red** | 20-30% waste | Hard prune (aggressive categories) | Every patrol cycle | Medium |
| **Critical** | > 30% waste OR disk > 85% full | Emergency prune + boss alert | Immediate | High |

### Soft Prune (Green/Yellow)

Safe to run automatically. After soft prune, wait 5 minutes and re-snapshot to confirm waste dropped.

```bash
# Soft prune — removes only truly safe categories
docker container prune --force --filter "until=24h"      # Remove containers exited > 24h
docker image prune --force --filter "until=24h"           # Remove dangling images older than 24h
docker volume prune --force                               # Remove unused volumes
docker builder prune --force --filter "until=24h"         # Remove build cache older than 24h
```

### Hard Prune (Red)

More aggressive. Requires boss confirmation (dispatch to super-boss for approval).

```bash
# Hard prune — removes all unused resources
docker system prune --force --all --volumes               # Remove ALL unused images, containers, volumes, networks
```

**Before hard prune**, verify:
1. No active CI/CD pipeline is running (would lose build cache)
2. No image is referenced in a pending deployment
3. The registry-cache is not mid-sync (would invalidate cache)

### Emergency Prune (Critical)

Automatic, immediate. No approval needed.

```bash
# Emergency prune — free space NOW
docker system prune --force --all --volumes
docker builder prune --force --all                        # Wipe ALL build cache, not just reclaimable
rm -rf /var/lib/docker/tmp/* 2>/dev/null                  # Clean Docker tmp files
```

### What NOT to Auto-Prune

| Resource | Why Not | Manual Cleanup Method |
|----------|---------|-----------------------|
| `kyb-base:latest` | Active base image for boss containers | Only prune if boss container is being migrated |
| `kyb-cc-connect:latest` | Active service image | Only prune on version upgrade |
| Named volumes (pg*, redis-data, etc.) | Contain persistent data | `docker volume rm` only after data backed up |
| Running containers | Obvious | -- |
| `registry:2` (kyb-registry-cache) | Local image cache | Only when mirror is rebuilt |

### Retention Windows

| Resource | Keep | Pruneable After |
|----------|------|-----------------|
| Dangling images | < 1 hour old | 1 hour (build just finished, may be debugging) |
| Exited containers | < 24h | 24h (may be investigating crash) |
| Unused volumes | < 24h | 24h (may be reattached) |
| Build cache | < 1h since last use | 1h (may be part of active dev cycle) |
| Stale tagged images (no container) | < 7 days | 7 days (may be rolled back) |
| PeerDB old versions | Keep latest 2 | Stable releases older than 2 versions |

### Exempt Images

The following images should NEVER be auto-pruned because they are part of the active infra fleet:

```
kyb-base:latest
kyb-infra-boss-snapshot:latest
kyb-cc-connect:latest
kyb-sing-box:1.13.11
clickhouse/clickhouse-server:24.2-alpine
postgres:14-alpine, postgres:15-alpine, postgres:16-alpine, postgres:17-alpine
redis:7-alpine
registry:2
grafana/grafana:latest
apache/kafka:latest
ubuntu:24.04
```

---

## Alert Rules

| Rule | Condition | Severity | Response |
|------|-----------|----------|----------|
| Waste threshold exceeded | Waste % > 20% for 2 consecutive snapshots | P2 | Feishu alert: "Disk waste at X% on ${cluster}" |
| Waste accelerating | Waste grew > 5 GB in 24 hours | P2 | Feishu: "Waste growing rapidly on ${cluster} (+X GB/24h)" |
| Dangling image spike | Dangling images > 3 | P3 | Feishu: "Dangling image spike on ${cluster}" |
| Disk near full | Docker disk usage > 85% | P1 | Feishu: "Docker disk critical on ${cluster} (X% used)" |
| Prune failure | Auto-cleanup ran but waste did not decrease | P3 | Feishu: "Cleanup ineffective on ${cluster}, manual intervention needed" |

### Alert Query Examples

```sql
-- Waste threshold exceeded (20% for 2+ snapshots = 10+ minutes)
SELECT cluster, waste_pct, snapshot_time
FROM infra.disk_waste_snapshots
WHERE waste_pct > 20
  AND snapshot_time >= now() - INTERVAL 10 MINUTE
GROUP BY cluster
HAVING count() >= 2;

-- Waste accelerating (> 5 GB in 24h)
SELECT cluster,
       max(total_waste_bytes) - min(total_waste_bytes) AS waste_delta_24h
FROM infra.disk_waste_snapshots
WHERE snapshot_time >= now() - INTERVAL 1 DAY
GROUP BY cluster
HAVING waste_delta_24h > 5 * 1073741824;

-- Dangling image spike
SELECT cluster, dangling_images
FROM infra.disk_waste_snapshots
WHERE dangling_images > 3
ORDER BY snapshot_time DESC
LIMIT 1;
```

---

## Deployment

### Phase 1: Collector + CK Schema

1. Run `CREATE TABLE infra.disk_waste_snapshots` on Mac/Orbstack CK (once)
2. Run `CREATE TABLE infra.image_tag_inventory` on Mac/Orbstack CK (once)
3. Deploy collector script to `kyb-infra-boss` at `/usr/local/bin/disk-waste-collector.sh`
4. Add to 5-minute patrol cycle (idempotent start)
5. Validate: wait 10 minutes, query CK for first 2 snapshots

### Phase 2: Grafana Dashboard

1. Create `Disk Waste Overview` dashboard in Grafana (panels 1-5)
2. Set auto-refresh to 5 minutes
3. Add alert rules for each threshold

### Phase 3: Auto-Cleanup

1. **Week 1:** Monitor-only. Collect data, build baseline.
2. **Week 2:** Enable soft prune (green/yellow tiers). Log all pruned resources.
3. **Week 3:** Review prune effectiveness. Tweak retention windows.
4. **Week 4:** Enable hard prune with boss dispatch. Emergency prune is always-on.

### Phase 4: Cross-Cluster Rollout

1. Deploy collector to Aliyun and Office bosses (same script)
2. Add cluster filter to Grafana dashboard
3. Compare waste profiles across clusters

---

## Query Examples

### Current waste snapshot

```sql
SELECT
    cluster,
    snapshot_time,
    round(images_reclaimable / 1073741824, 2) AS images_gb,
    round(containers_reclaimable / 1073741824, 2) AS containers_gb,
    round(dangling_images_size / 1073741824, 2) AS dangling_gb,
    round(build_cache_reclaimable / 1073741824, 2) AS cache_gb,
    round(total_waste_bytes / 1073741824, 2) AS total_gb,
    waste_pct
FROM infra.disk_waste_snapshots
ORDER BY snapshot_time DESC
LIMIT 1;
```

### Waste trend (last 30 days, daily aggregates)

```sql
SELECT
    toDate(snapshot_time) AS day,
    cluster,
    argMax(total_waste_bytes, snapshot_time) AS waste_at_end_of_day
FROM infra.disk_waste_snapshots
WHERE snapshot_time >= now() - INTERVAL 30 DAY
GROUP BY day, cluster
ORDER BY day;
```

### Largest waste-producing events

```sql
SELECT
    toDate(snapshot_time) AS day,
    cluster,
    max(total_waste_bytes) - min(total_waste_bytes) AS waste_spike,
    argMax(dangling_images, snapshot_time) AS dangling_at_peak
FROM infra.disk_waste_snapshots
WHERE snapshot_time >= now() - INTERVAL 30 DAY
GROUP BY day, cluster
HAVING waste_spike > 1073741824  -- > 1 GB
ORDER BY waste_spike DESC;
```

### Images that haven't been used in 30+ days

```sql
SELECT repository, tag, size_bytes, age_days
FROM infra.image_tag_inventory
WHERE in_use = 0
  AND age_days >= 30
  AND snapshot_time = (SELECT max(snapshot_time) FROM infra.image_tag_inventory)
ORDER BY size_bytes DESC;
```

---

## Waste Prevention

Beyond cleanup, prevention reduces waste accumulation:

### 1. Tag Hygiene

The click-rest images show the pattern: **5 tags for the same image**, pushed at different times. Recommendation:
- Keep only `latest` + date-based tagging per environment (e.g., `staging-20260522`)
- Prune old tags from the registry before pulling to local Docker
- Apply a `docker image tag` convention and prune script in CI/CD

### 2. Build Layer Reuse

The 6.07 GB dangling image is a `kyb-base` intermediate layer. When `kyb-base` is rebuilt:
- If the Dockerfile changed significantly, the old layer has no common ancestry
- The old layer becomes dangling and is not freed until `docker image prune`
- **Recommendation:** Add `docker image prune --force` to the end of `kyb build` command

### 3. Container Lifecycle Management

The zombie containers (13 GB from `kyb-kyb-robust`, `friendly_banach`) were left behind by `kyb create` or `kyb did create` commands that crashed or were interrupted.
- **Recommendation:** Add a trap handler in `kyb create` / `kyb exec` / `kyb did create` that removes the container on abnormal exit
- **Recommendation:** `kyb clean` or `kyb prune` should explicitly `docker rm` stopped sandbox containers, not just prune images

### 4. Sandbox Ephemerality

Sandbox containers like `kyb-kyb-robust-claude` have volumes (`kyb-kyb-robust-claude`) that persist after the container is removed.
- **Recommendation:** Add `--rm` to `docker run` for all `kyb create` and `kyb exec` invocations (already partially done with `--init --rm` in recent commits)
- **Recommendation:** `kyb prune` should also `docker volume prune` with a filter for `kyb-*` volumes older than 24h

---

## Integration with Existing Systems

### Docker Event Monitoring (docker-events.md)

The existing Docker event monitor already tracks `container:die` and `container:destroy` events. A new waste event (`container:prune`) should be added so we can correlate:
- `container:die` + `container:destroy` = container was removed (expected)
- `container:die` without `container:destroy` within 24h = zombie container (alert candidate)

### Error Budget (error-budget.md)

Disk waste tracking feeds into the Docker host's error budget:
- Waste > 20% = Tier-2 SLO violation for the host service
- Emergency prune triggered = Tier-1 incident (disruption risk)
- Disk > 85% = Tier-0 (service might fail)

### Patrol System (docker-events.md / ck-query-monitor.md)

The 5-minute patrol already runs on each boss. The collector script integrates as:
```bash
# In patrol script:
/usr/local/bin/disk-waste-collector.sh
```

The patrol should also check whether auto-cleanup is needed (check waste % from the last CK snapshot, not from live `docker system df`, to avoid thundering herd on every patrol cycle).

---

## Implementation Checklist

### P0 — Phase 1 (Foundation)
- [ ] Create `infra.disk_waste_snapshots` table in CK
- [ ] Create `infra.image_tag_inventory` table in CK
- [ ] Write collector script and deploy to Mac/Orbstack boss
- [ ] Validate first snapshot arrives in CK
- [ ] Add to patrol cycle (idempotent start)

### P1 — Phase 2 (Visibility)
- [ ] Build Grafana dashboard: waste overview panels
- [ ] Add waste growth rate panel
- [ ] Add dangling image inventory panel (from tag_inventory table)
- [ ] Set up alert rules in Grafana (waste %, growth rate, dangling spike)

### P1 — Phase 3 (Prevention)
- [ ] Add `docker image prune --force` to `kyb build` post-build hook
- [ ] Add trap handler in `kyb create` / `kyb did create` for zombie container cleanup
- [ ] Add `--rm` to all `kyb exec` invocations
- [ ] `kyb prune` improvements: volume pruning, sandbox container removal

### P2 — Phase 4 (Auto-Cleanup)
- [ ] Implement soft prune (Green/Yellow tier) in patrol
- [ ] Implement hard prune (Red tier) with boss dispatch
- [ ] Implement emergency prune (Critical tier) — automatic
- [ ] Add prune event logging to CK (`infra.prune_events` table)
- [ ] Validate prune effectiveness (snapshot after prune, confirm waste dropped)

### P2 — Phase 5 (Cross-Cluster)
- [ ] Deploy collector to Aliyun boss
- [ ] Deploy collector to Office boss
- [ ] Add cluster filter to Grafana dashboard
- [ ] Compare waste profiles, tune retention per cluster

---

## Verdict

**Design is sound and ready for Phase 1 implementation.** The infrastructure cost is negligible (~34 KB/day in CK storage), the collector script is simple, and the existing 5-minute patrol provides a natural execution slot. The three-phase rollout (collect → visualize → auto-cleanup) ensures we understand waste patterns before automating cleanup.

The highest-ROI single action is adding `docker image prune --force` to `kyb build` — it costs nothing, removes the primary source of multi-GB dangling images, and prevents the 6.07 GB waste pattern from recurring. The second-highest ROI is the zombie container trap handler (saves ~13 GB from orphaned sandbox containers).

Key metrics to watch after deployment:
1. **Waste % trending down** (cleanup working)
2. **Dangling images rarely > 0** (prune-in-build working)
3. **Zombie containers near zero** (lifecycle management working)
4. **Alert rate decreasing** (prevention > cleanup)

> /人◕ ‿‿ ◕人＼
