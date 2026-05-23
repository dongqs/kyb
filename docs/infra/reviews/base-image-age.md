---
decision: 稍后做
---

# Design: Container Base Image Age Tracking

**Design doc**: `docs/infra/reviews/base-image-age.md`
**Reviewer**: kyb
**Date**: 2026-05-23
**Scope**: Base image age monitoring, vulnerability scanning, tag freshness, rebuild policy

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Current State](#2-current-state)
3. [Image Inventory](#3-image-inventory)
4. [Age Tracking Design](#4-age-tracking-design)
5. [Vulnerability Scanning](#5-vulnerability-scanning)
6. [Tag Freshness](#6-tag-freshness)
7. [Update Policy](#7-update-policy)
8. [ClickHouse Schema](#8-clickhouse-schema)
9. [Collection Script](#9-collection-script)
10. [Alerting](#10-alerting)
11. [Grafana Dashboard](#11-grafana-dashboard)
12. [Rollout Plan](#12-rollout-plan)

---

## 1. Problem Statement

The multi-cluster infra runs multiple Docker images across three clusters. Today there is no visibility into:

| Gap | Risk |
|-----|------|
| **Base image age** -- how many days since `kyb-base` or `ubuntu:24.04` was last rebuilt? | Stale base images lack security patches. `apt-get upgrade` at build time is the only patch window. |
| **Upstream image drift** -- `ubuntu:24.04` receives new layers weekly. When was our last `docker pull ubuntu:24.04`? | Critical CVEs accumulate. Log4j-style zero-days need a known baseline to assess blast radius. |
| **Vulnerability state** -- no CVE scanning pipeline exists. | Unknown exposure. A `docker build` that succeeds may embed known-critical packages. |
| **Tag staleness** -- `latest` tags are pointers. If a build fails, old images linger. | Containers start from stale caches. Rollback is blind (no versioned tags for base images). |
| **Rebuild cadence** -- no policy for when to rebuild. | `kyb build` runs only when Dockerfile or entrypoint.sh changes (hash check). Upstream base image updates are invisible. |

### What We Need

- Track image creation date, base image date, days since build per image per cluster.
- Run periodic vulnerability scans (integrate Trivy) and store results.
- Monitor `latest` tag freshness: did the upstream `ubuntu:24.04` publish a new layer since our last build?
- Define a clear update policy: when to rebuild, who decides, how to roll back.
- Alert when an image exceeds its maximum permitted age or when a critical CVE is detected.

---

## 2. Current State

### 2.1 Build System (`kyb build`)

The current build system in `lib/kyb/docker.rb`:

```ruby
BUILD_HASH_FILES = %w[Dockerfile entrypoint.sh].freeze

def build(tag, path, proxy: nil)
  build_hash = compute_build_hash(path)
  args = ['docker', 'build', '-t', tag, '--label']
  args << "kyb.build-hash=#{build_hash}"
  # ...
end
```

Key characteristics:
- **Hash-based staleness check**: `kyb create` detects if `Dockerfile` or `entrypoint.sh` changed vs. the label on `kyb-base:latest`. If unchanged, no rebuild.
- **No upstream check**: Never pulls `ubuntu:24.04` to check for new layers. The build caches the old base indefinitely.
- **Single tag**: Only `latest` is produced. No date-stamped or build-number tags.
- **No scan step**: Build succeeds or fails on `docker build` exit code. No CVE gate.

### 2.2 Image Age Snapshot (Mac/Orbstack, 2026-05-23)

| Image | Created | Age | Base Image | Base Image Created | Base Drift |
|-------|---------|-----|------------|-------------------|------------|
| `kyb-base:latest` | 2026-05-23 | 0 days | `ubuntu:24.04` | 2026-04-10 | 43 days |
| `kyb-infra-boss-snapshot:latest` | 2026-05-23 | 0 days | `kyb-base:latest` | 2026-05-23 | 0 days |
| `kyb-cc-connect:latest` | 2026-05-23 | 0 days | (Go binary) | N/A | N/A |
| `kyb-sing-box:1.13.11` | 2026-05-22 | 1 day | (Go binary) | N/A | N/A |
| `kyb-base-sshd:latest` | 2026-05-20 | 3 days | `ubuntu:24.04` | 2026-04-10 | 43 days |
| `clickhouse/clickhouse-server:head-alpine` | 2026-05-22 | 1 day | `alpine` | (continuous) | Hours |
| `postgres:16-alpine` | unknown | unknown | `alpine` | (continuous) | Unknown |
| `postgres:14-alpine` | 2026-05-22 | 1 day | `alpine` | (continuous) | Hours |
| `postgres:15-alpine` | 2026-05-22 | 1 day | `alpine` | (continuous) | Hours |
| `postgres:17-alpine` | 2026-05-22 | 1 day | `alpine` | (continuous) | Hours |
| `redis:7-alpine` | unknown | unknown | `alpine` | (continuous) | Unknown |
| `grafana/grafana:latest` | 2026-05-22 | 1 day | `alpine` | (continuous) | Unknown |
| `apache/kafka:latest` | 2026-05-22 | 1 day | `eclipse-temurin` | (continuous) | Unknown |
| `registry:2` | 2026-05-22 | 1 day | `alpine` | (continuous) | Unknown |

**Key observation**: `ubuntu:24.04` was created on 2026-04-10, which means the currently-cached base is 43 days old. All `kyb-base*` images inherit any CVEs that accumulated in `ubuntu:24.04` between April 10 and the build date.

### 2.3 Upstream Cadence

| Base Image | Update Frequency | Notes |
|------------|-----------------|-------|
| `ubuntu:24.04` | Weekly (security), Monthly (all) | Canonical publishes security patches every Thursday. `apt-get update` catches these at build time. |
| `alpine` | Weekly | Edge releases are daily; stable is weekly. |
| `postgres:*-alpine` | Per PG minor version | Point releases every 2-3 months. |
| `redis:7-alpine` | Per Redis patch | ~2-3 months between patch releases. |
| `grafana/grafana:latest` | ~2 weeks | Regularly ships security fixes. |
| `apache/kafka:latest` | ~1-2 months | Confluent/RH builds. |
| `registry:2` | ~3-4 months | Stable, infrequent updates. |

---

## 3. Image Inventory

### 3.1 Built In-House

These images are built from Dockerfiles in the kyb repo:

| Image | Dockerfile | Build Frequency | Base |
|-------|-----------|----------------|------|
| `kyb-base` | `Dockerfile` | On-demand (`kyb build`) | `ubuntu:24.04` |
| `kyb-infra-boss-snapshot` | Manual snapshot | Rare (debugging) | `kyb-base` |
| `kyb-cc-connect` | External repo | CI pipeline | Go distroless |
| `kyb-sing-box` | External repo | CI pipeline | Go distroless |
| `kyb-base-sshd` | `Dockerfile` variant | Rare (debugging) | `ubuntu:24.04` |

### 3.2 Third-Party (Pulled Upstream)

These images are used as-is or via registry mirrors:

| Image | Source | Registry Mirror |
|-------|--------|-----------------|
| `clickhouse/clickhouse-server:head-alpine` | Docker Hub | `docker.xuanyuan.me` |
| `postgres:14-alpine` | Docker Hub | `docker.xuanyuan.me` |
| `postgres:15-alpine` | Docker Hub | `docker.xuanyuan.me` |
| `postgres:16-alpine` | Docker Hub | `docker.xuanyuan.me` |
| `postgres:17-alpine` | Docker Hub | `docker.xuanyuan.me` |
| `redis:7-alpine` | Docker Hub | `docker.xuanyuan.me` |
| `grafana/grafana:latest` | Docker Hub | `docker.xuanyuan.me` |
| `apache/kafka:latest` | Docker Hub | `docker.xuanyuan.me` |
| `registry:2` | Docker Hub | `docker.xuanyuan.me` |

---

## 4. Age Tracking Design

### 4.1 Approach

Track four age values per image:

1. **Image creation age**: `now() - image_created_at` (how long since this specific image ID was built)
2. **Base image age**: `now() - base_image_created_at` (how old is the FROM image at build time)
3. **Base image drift**: `now() - base_image_created_at` for the *current upstream* (if we pulled `ubuntu:24.04` right now, how old would it be vs. the one we cached)
4. **Days since last pull**: `now() - last_pull_at` (how long since we explicitly refreshed this image)

### 4.2 Data Flow

```
Each boss (daily cron or on image use)
    │  docker inspect + docker history
    │  curl POST to ClickHouse
    ▼
ClickHouse: infra.image_ages (raw snapshots)
    │
    ├── Grafana dashboard (image age trends, drift alerts)
    └── Alert system (critical age / CVE thresholds)
```

### 4.3 Metrics Per Image

| Field | Type | Source | Example |
|-------|------|--------|---------|
| `cluster` | LowCardinality(String) | config | `mac-orbstack` |
| `boss_id` | String | hostname | `kyb-infra-boss` |
| `collected_at` | DateTime64(3) | now() | `2026-05-23T12:00:00.000Z` |
| `image_name` | String | `docker images --format` | `kyb-base` |
| `image_tag` | String | `docker images --format` | `latest` |
| `image_id` | String | `docker images --digests` | `sha256:50d36a67c3a1` |
| `created_at` | DateTime64(3) | `docker inspect --format '{{.Created}}'` | `2026-05-23T10:53:58Z` |
| `age_days` | Float32 | computed | `0.04` |
| `size_bytes` | UInt64 | `docker inspect --format '{{.Size}}'` | `8687350249` |
| `base_image` | String | `docker history --format` (first FROM) | `ubuntu:24.04` |
| `base_image_id` | String | `docker image inspect ubuntu:24.04 --format '{{.Id}}'` | `sha256:abc...` |
| `base_image_created_at` | DateTime64(3) | `docker inspect ubuntu:24.04` | `2026-04-10T06:56:54Z` |
| `base_image_age_days` | Float32 | computed | `43` |
| `base_image_drift_days` | Nullable(Float32) | upstream check | `0.5` |
| `last_pull_at` | Nullable(DateTime64(3)) | `docker inspect --format` pull time | `2026-05-22T08:00:00Z` |
| `vuln_critical` | UInt16 | Trivy scan | `3` |
| `vuln_high` | UInt16 | Trivy scan | `12` |
| `vuln_medium` | UInt16 | Trivy scan | `28` |
| `vuln_low` | UInt16 | Trivy scan | `45` |
| `vuln_scanned_at` | Nullable(DateTime64(3)) | scan timestamp | `2026-05-23T12:00:00Z` |
| `rebuild_pending` | Bool | policy check | `true` |
| `in_use` | Bool | `docker ps --filter ancestor=...` | `true` |

### 4.4 Computing Base Image Drift

For images with a known upstream base (e.g., `ubuntu:24.04`), check whether the upstream has published new layers since our last pull:

```bash
# Pull the upstream manifest (no layers, just manifest + config)
# Compare config.Created with our cached base image's Created
docker pull ubuntu:24.04 --platform linux/amd64 2>/dev/null
UPSTREAM_CREATED=$(docker inspect ubuntu:24.04 --format '{{.Created}}')
CACHED_CREATED=$(docker image inspect ubuntu:24.04 --format '{{.Created}}')

if [ "$UPSTREAM_CREATED" != "$CACHED_CREATED" ]; then
  # Upstream has a new image. Our cached base image is stale.
  DRIFT_HOURS=$(python3 -c "
from datetime import datetime, timezone
u = datetime.fromisoformat('$UPSTREAM_CREATED'.replace('Z', '+00:00'))
c = datetime.fromisoformat('$CACHED_CREATED'.replace('Z', '+00:00'))
print((u - c).total_seconds() / 3600)
  ")
fi
```

If the cached `ubuntu:24.04` has the same ID as upstream, drift is 0 (we are current). Otherwise drift = upstream creation date - cached creation date (in hours/days).

---

## 5. Vulnerability Scanning

### 5.1 Tool: Trivy

[Trivy](https://github.com/aquasecurity/trivy) is the recommended scanner:
- Open source, Apache 2.0 license
- Scans OS packages (apt, apk, rpm) and language dependencies (pip, npm, gem, etc.)
- No persistent database needed (downloads vulnerability DB on first run, caches it)
- Fast: ~10-30 seconds per image after initial DB download
- Exit code based: `trivy image --exit-code 1 --severity CRITICAL,HIGH <image>`

### 5.2 Scan Pipeline

```bash
#!/bin/bash
# scan-image.sh — Run Trivy scan on an image and report results to CK
# Usage: scan-image.sh <image_name>:<tag>

IMAGE="${1:-kyb-base:latest}"
TRIVY_DB_DIR="${TRIVY_DB_DIR:-/home/dev/.cache/trivy}"

# Ensure Trivy is installed
if ! command -v trivy &> /dev/null; then
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
fi

# Update vulnerability DB (daily)
trivy image --download-db-only --cache-dir "$TRIVY_DB_DIR" 2>/dev/null || true

# Run scan, output JSON
SCAN_OUTPUT=$(trivy image --cache-dir "$TRIVY_DB_DIR" \
  --format json \
  --severity CRITICAL,HIGH,MEDIUM,LOW \
  --ignore-unfixed \
  "$IMAGE" 2>/dev/null)

# Extract counts
CRITICAL=$(echo "$SCAN_OUTPUT" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    results = r.get('Results', [])
    total = sum(len(v.get('Vulnerabilities', [])) for v in results)
    print(total)
except:
    print(0)
")

HIGH=$(echo "$SCAN_OUTPUT" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    total = sum(1 for res in r.get('Results', [])
                for vuln in res.get('Vulnerabilities', [])
                if vuln.get('Severity') == 'HIGH')
    print(total)
except:
    print(0)
")

# ... similarly for MEDIUM, LOW

# Report to CK
CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"
curl -s -X POST "$CK_HOST" \
  -H "Content-Type: text/plain" \
  --data-binary @- << PAYLOAD
INSERT INTO infra.image_vulnerabilities FORMAT JSONEachRow
{
  "image_name": "$(echo "$IMAGE" | cut -d: -f1)",
  "image_tag": "$(echo "$IMAGE" | cut -d: -f2)",
  "scanned_at": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "severity": "CRITICAL",
  "count": $CRITICAL,
  "scanner": "trivy"
}
PAYLOAD
```

### 5.3 Scan Schedule

| Image | Scan Frequency | Notes |
|-------|---------------|-------|
| `kyb-base:latest` | Daily | Most critical — base of all sandboxes |
| `ubuntu:24.04` | Daily (or on pull) | Upstream base, source of most CVEs |
| `kyb-cc-connect:latest` | Weekly | Go binary, fewer CVEs |
| `kyb-sing-box:*` | Weekly | Go binary |
| `postgres:*-alpine` | Weekly after build | Alpine has few CVEs |
| `redis:7-alpine` | Weekly | |
| All other third-party | Monthly | Stable, infrequently updated |

### 5.4 CVE Severity Thresholds

| Severity | Critical Count Threshold | Action |
|----------|-------------------------|--------|
| CRITICAL | >= 1 | **P1 alert** — rebuild immediately or pin specific package fix |
| HIGH | >= 10 | P2 alert — schedule rebuild within 7 days |
| HIGH | >= 25 | P1 alert — urgent rebuild |
| MEDIUM | >= 50 | P3 alert — review at next maintenance window |

Thresholds are tuned for a sandbox container environment (not production). A sandbox with some CVEs is acceptable; a sandbox with known remote-code-execution CVEs is not.

---

## 6. Tag Freshness

### 6.1 Problem: `latest` Is a Mutable Pointer

Currently all built images use only the `latest` tag. This is problematic:

```
Before build:
  kyb-base:latest -> sha256:abc (built 2026-05-01)

After successful build:
  kyb-base:latest -> sha256:def (built 2026-05-23)

On build failure:
  kyb-base:latest -> sha256:abc (unchanged — good, but no versioned reference)
```

Without versioned tags, you cannot:
- Roll back to a known-good build
- Compare builds across dates
- Know which build a running container was started from (without `docker inspect`)

### 6.2 Proposal: Date-Stamped Tags

Every `kyb build` should produce two tags:

```bash
# Current behavior (keep for convenience)
docker build -t kyb-base:latest ...

# Additional — date-stamped tag
DATE_TAG="kyb-base:$(date +%Y%m%d)"
docker build -t "$DATE_TAG" ...

# Additional — date+time tag for same-day rebuilds
FULL_TAG="kyb-base:$(date +%Y%m%dT%H%M%S)"
docker build -t "$FULL_TAG" ...
```

This adds ~1 second to the build (tag-only, no additional layer). The `latest` pointer still works for automatic updates, while versioned tags enable rollback:

```bash
# Rollback (if needed)
docker tag kyb-base:20260522 kyb-base:latest
docker rm -f kyb-infra-boss
kyb create infra-boss --extra-mount /var/run/docker.sock:/var/run/docker.sock
```

### 6.3 Implementation in `kyb build`

In `lib/kyb/docker.rb`, modify the `build` method:

```ruby
def build(tag, path, proxy: nil)
  date_tag = "#{tag}:#{Time.now.strftime('%Y%m%d')}"
  full_tag = "#{tag}:#{Time.now.strftime('%Y%m%dT%H%M%S')}"

  args = ['docker', 'build', '-t', tag, '-t', date_tag, '-t', full_tag, '--label']
  # ... rest unchanged

  # Also update a "latest-build-date" label for CK tracking
  args += ['--label', "kyb.build-date=#{Time.now.utc.iso8601}"]
end
```

Third-party image freshness is tracked differently. For `ubuntu:24.04`, `postgres:16-alpine`, etc., we track the `Created` timestamp difference between our cached copy and the upstream manifest:

| Image | Our Cached Created | Latest Upstream Created | Drift | Action Needed |
|-------|-------------------|----------------------|-------|---------------|
| `ubuntu:24.04` | 2026-04-10 | 2026-05-16 | 36 days | `docker pull` before next build |
| `postgres:16-alpine` | 2026-05-22 | 2026-05-23 | 1 day | None (current) |
| `redis:7-alpine` | Unknown | 2026-05-20 | N/A | Run first pull |

### 6.4 Freshness Rules

| Image Type | Max Acceptable Drift | Action |
|------------|---------------------|--------|
| `ubuntu:24.04` (cached) | 14 days | Pull latest before next `kyb build` |
| `kyb-base:latest` | 30 days since build | Trigger rebuild |
| Third-party service images | 90 days since pull | `docker pull` to refresh |
| Pin-versioned images (`postgres:16-alpine`) | 60 days | Check for new minor version |

---

## 7. Update Policy

### 7.1 When to Rebuild `kyb-base`

| Trigger | Priority | Action |
|---------|----------|--------|
| Dockerfile or entrypoint.sh changed | Automatic | `kyb build` on next `kyb create` |
| `ubuntu:24.04` upstream base > 14 days older than cached | P2 | Schedule `kyb build` |
| `kyb-base` age > 30 days | P2 | Schedule `kyb build` |
| Critical CVE detected in `kyb-base` or `ubuntu:24.04` | **P1** | Rebuild immediately |
| New Ruby/Node/Python toolchain version in `mise.config.toml` | P3 | Rebuild at next maintenance |
| High CVE count > 25 in `kyb-base` | P2 | Rebuild within 7 days |

### 7.2 When to Update Third-Party Service Images

| Trigger | Priority | Action |
|---------|----------|--------|
| New PG minor version released | P2 | Pull and restart within 14 days |
| Grafana security advisory | **P1** | Pull and restart within 24h |
| Redis/ClickHouse/Kafka security patch | P2 | Pull and restart within 7 days |
| Third-party image age > 90 days since last pull | P3 | Pull and restart |
| `registry:2` major version upgrade | P3 | Plan migration (rare) |

### 7.3 Rebuild vs. Pull vs. Restart

For built images (`kyb-base`):

```bash
# Full rebuild cycle
kyb build                             # Step 1: Build with updated base
docker rm -f <container>              # Step 2: Stop old container
kyb create <name>                     # Step 3: Create with new image
```

For third-party service images:

```bash
# Refresh cycle
docker pull postgres:16-alpine        # Step 1: Pull latest
docker rm -f kyb-infra-postgresql-16  # Step 2: Stop old container
# Step 3: Re-create with same docker run args but new image
# (Use the previously saved docker run command from inspect)
docker run -d --name kyb-infra-postgresql-16 \
  --restart unless-stopped \
  -e POSTGRES_PASSWORD=postgres \
  -v kyb-pg16-data:/var/lib/postgresql/data \
  postgres:16-alpine
```

### 7.4 Rollback Procedure

If a rebuild introduces issues:

```bash
# Step 1: Revert latest tag to previous build
docker tag kyb-base:20260522 kyb-base:latest

# Step 2: Restart affected containers
docker rm -f kyb-infra-boss
kyb create infra-boss --extra-mount /var/run/docker.sock:/var/run/docker.sock

# Step 3: Verify
kyb preflight

# Step 4: Investigate the failed build
#   Check build logs, diff Dockerfile changes, test in isolation
```

For third-party image rollbacks, use the specific digest:

```bash
# Rollback postgres to a known-good digest
docker pull postgres:16-alpine@sha256:<known-good-digest>
docker tag postgres:16-alpine@sha256:<known-good-digest> postgres:16-alpine
```

### 7.5 Maintenance Window

| Rebuild Type | Window | Notify |
|-------------|--------|--------|
| Scheduled rebuild (age/CVE counts) | Any time (sandboxes restart transparently) | No (quiet) |
| Urgent rebuild (critical CVE) | Immediate | Yes: `kyb notify urgent "Rebuilding kyb-base for CVE-xxxx"` |
| Third-party update (planned) | Off-peak (UTC night) | No (quiet) |
| Third-party update (security) | Within SLA per severity | Yes |

---

## 8. ClickHouse Schema

### 8.1 Image Ages Table

```sql
CREATE TABLE infra.image_ages (
    -- Identity
    cluster         LowCardinality(String),       -- mac-orbstack | aliyun | office
    boss_id         String,                       -- hostname of the boss container
    collected_at    DateTime64(3),                -- when this snapshot was taken

    -- Image identity
    image_name      String,                       -- kyb-base, ubuntu, postgres, etc.
    image_tag       String,                       -- latest, 16-alpine, 1.13.11
    image_id        String,                       -- full sha256 digest
    registry        LowCardinality(String) DEFAULT 'docker.io',

    -- Age metrics
    created_at      DateTime64(3),                -- docker inspect .Created
    age_days        Float32,                      -- now() - created_at, in days
    size_bytes      UInt64,

    -- Base image chain (FROM)
    base_image      String DEFAULT '',            -- ubuntu:24.04
    base_image_id   String DEFAULT '',            -- sha256 of cached base
    base_image_created_at DateTime64(3),
    base_image_age_days Float32,                  -- now() - base_image_created_at
    base_image_drift_days Nullable(Float32),      -- upstream latest - cached, in days
    last_pull_at    Nullable(DateTime64(3)),

    -- Build metadata (for built images)
    build_hash      String DEFAULT '',            -- kyb.build-hash label
    build_date      String DEFAULT '',            -- kyb.build-date label (ISO8601)

    -- Operational
    in_use          Bool DEFAULT false,           -- true if any running container uses this
    rebuild_pending Bool DEFAULT false,           -- policy says rebuild needed

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
PARTITION BY toYYYYMM(collected_at)
ORDER BY (cluster, image_name, collected_at)
TTL collected_at + INTERVAL 180 DAY;
```

**Design notes:**

1. **Partition by month**: Volume is tiny (3 clusters x ~20 images x 1 snapshot/day = 60 rows/day = 1800 rows/month). Partitioning is for cleanup convenience.
2. **TTL 180 days**: 6 months of history is sufficient for age trend analysis.
3. **ORDER BY (cluster, image_name, collected_at)**: Supports per-cluster and per-image time series queries.
4. **base_image_drift_days as Nullable**: NULL if the base image has no upstream (e.g., distroless) or upstream check failed.

### 8.2 Image Vulnerabilities Table

```sql
CREATE TABLE infra.image_vulnerabilities (
    -- Identity
    cluster         LowCardinality(String),
    boss_id         String,
    scanned_at      DateTime64(3),

    -- Image
    image_name      String,
    image_tag       String,
    image_id        String DEFAULT '',

    -- Vulnerability summary
    scanner         LowCardinality(String),       -- trivy | grype
    severity        LowCardinality(String),       -- CRITICAL | HIGH | MEDIUM | LOW | UNKNOWN
    count           UInt32,

    -- Top CVEs (for drill-down)
    top_cves        String DEFAULT '',            -- JSON array: ["CVE-2026-1234", "CVE-2026-5678"]

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
PARTITION BY toYYYYMM(scanned_at)
ORDER BY (image_name, severity, scanned_at)
TTL scanned_at + INTERVAL 90 DAY;
```

### 8.3 Image Freshness Policy Table

```sql
CREATE TABLE infra.image_freshness_policy (
    image_name      String,
    image_tag       String,
    max_age_days    UInt16,                      -- 30 for kyb-base, 90 for third-party
    max_drift_days  UInt16,                      -- 14 for ubuntu:24.04
    scan_frequency  LowCardinality(String),      -- daily | weekly | monthly
    rebuild_on_cve  Bool DEFAULT true,           -- auto-trigger rebuild on critical CVE
    notes           String DEFAULT '',

    _updated_at     DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree
ORDER BY (image_name, image_tag);
```

Pre-populate with current policy:

```sql
INSERT INTO infra.image_freshness_policy VALUES
('kyb-base',          'latest',  30, 14, 'daily',   true,  'Primary sandbox base image'),
('ubuntu',            '24.04',    7,  7, 'daily',   true,  'Upstream OS base for kyb-base'),
('kyb-cc-connect',    'latest',  90,  0, 'weekly',  true,  'Go binary, few CVEs'),
('kyb-sing-box',      '*',       90,  0, 'weekly',  true,  'Go binary, few CVEs'),
('postgres',          '16-alpine', 60, 0, 'weekly', false, 'PG minor version stable'),
('postgres',          '15-alpine', 60, 0, 'weekly', false, ''),
('postgres',          '14-alpine', 60, 0, 'weekly', false, ''),
('postgres',          '17-alpine', 60, 0, 'weekly', false, ''),
('redis',             '7-alpine', 90, 0, 'monthly', false, 'Redis is very stable'),
('grafana',           'latest',  30,  0, 'weekly',  true,  'Frequent security releases'),
('clickhouse/clickhouse-server', 'head-alpine', 30, 0, 'weekly', true, ''),
('apache/kafka',      'latest',  60,  0, 'monthly', false, ''),
('registry',          '2',       90,  0, 'monthly', false, '');
```

---

## 9. Collection Script

### 9.1 Image Age Collection

Deployed to each infra-boss container at `/usr/local/bin/collect-image-ages.sh`:

```bash
#!/bin/bash
# collect-image-ages.sh — Collect Docker image ages and report to central ClickHouse
# Runs daily via cron on each boss.

set -euo pipefail

CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"
BOSS_ID="${BOSS_ID:-$(hostname)}"
CLUSTER="${CLUSTER:-unknown}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

# Get all images sorted by repository name (exclude intermediate build layers)
docker images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}\t{{.Size}}' \
  | sort \
  | while IFS=$'\t' read -r repo tag id created size_raw; do

  # Skip <none> tag images (intermediate)
  [ "$tag" = "<none>" ] && continue

  # Parse size
  size=$(echo "$size_raw" | numfmt --from=iec 2>/dev/null || echo 0)

  # Get creation timestamp in ISO format
  created_at=$(date -u -d "$created" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$created")
  age_days=$(python3 -c "
from datetime import datetime, timezone
c = datetime.fromisoformat('$created_at'.replace('Z', '+00:00'))
print(f'{(datetime.now(timezone.utc) - c).total_seconds() / 86400:.2f}')
" 2>/dev/null || echo "0")

  # Check if any running container uses this image
  in_use=0
  if docker ps --filter "ancestor=$repo:$tag" --format '{{.Names}}' 2>/dev/null | grep -q .; then
    in_use=1
  fi

  # Try to extract base image from docker history
  base_image=$(docker history --format '{{.CreatedBy}}' "$repo:$tag" 2>/dev/null \
    | grep -E '^FROM ' | head -1 | sed 's/^FROM //' || echo "")

  # Build JSON payload and send to CK
  payload=$(python3 -c "
import json
p = {
    'cluster': '$CLUSTER',
    'boss_id': '$BOSS_ID',
    'collected_at': '$NOW',
    'image_name': '$repo',
    'image_tag': '$tag',
    'image_id': 'sha256:$id',
    'created_at': '$created_at',
    'age_days': float('$age_days'),
    'size_bytes': int($size),
    'base_image': '$base_image',
    'in_use': bool($in_use),
    'rebuild_pending': False
}
print(json.dumps(p))
" 2>/dev/null)

  curl -s -X POST "$CK_HOST" \
    -H "Content-Type: text/plain" \
    --data-binary "INSERT INTO infra.image_ages FORMAT JSONEachRow $payload" \
    --max-time 5 2>/dev/null || true
done
```

### 9.2 Base Image Drift Check

Script to detect upstream drift (`/usr/local/bin/check-base-drift.sh`):

```bash
#!/bin/bash
# check-base-drift.sh — Compare cached base images against upstream
# Runs daily before image age collection.

set -euo pipefail

IMAGES_TO_CHECK=("ubuntu:24.04" "alpine:latest" "postgres:16-alpine" "redis:7-alpine")

for IMAGE in "${IMAGES_TO_CHECK[@]}"; do
  # Get cached image creation time
  CACHED_CREATED=$(docker image inspect "$IMAGE" --format '{{.Created}}' 2>/dev/null || echo "")

  if [ -z "$CACHED_CREATED" ]; then
    echo "[SKIP] $IMAGE not cached locally"
    continue
  fi

  # Pull manifest (no layers, just metadata)
  docker pull "$IMAGE" --platform linux/amd64 2>/dev/null || true

  UPSTREAM_CREATED=$(docker image inspect "$IMAGE" --format '{{.Created}}' 2>/dev/null || echo "")

  if [ "$CACHED_CREATED" != "$UPSTREAM_CREATED" ]; then
    echo "[DRIFT] $IMAGE: cached=$CACHED_CREATED upstream=$UPSTREAM_CREATED"
  else
    echo "[OK] $IMAGE: no drift"
  fi
done
```

### 9.3 Vulnerability Scan Integration

Deploy `/usr/local/bin/scan-images.sh` on the super-boss (Mac/Orbstack -- where most images live):

```bash
#!/bin/bash
# scan-images.sh — Run Trivy scan on key images and report to CK
# Runs daily on super-boss (Mac/Orbstack) via cron.

set -euo pipefail

CK_HOST="${CK_HOST:-http://100.104.244.99:8123}"
TRIVY_DB_DIR="${TRIVY_DB_DIR:-/home/dev/.cache/trivy}"
IMAGES_TO_SCAN=("kyb-base:latest" "ubuntu:24.04" "kyb-cc-connect:latest" "kyb-sing-box:*")

# Ensure Trivy is installed
if ! command -v trivy &> /dev/null; then
  echo "Installing Trivy..."
  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
    | sh -s -- -b /usr/local/bin v0.50.0
fi

# Update vulnerability DB (runs daily, incremental)
trivy image --download-db-only --cache-dir "$TRIVY_DB_DIR" 2>/dev/null || true

for IMAGE in "${IMAGES_TO_SCAN[@]}"; do
  echo "Scanning $IMAGE..."

  # Run scan, output JSON (ignore errors for missing images)
  SCAN_JSON=$(trivy image --cache-dir "$TRIVY_DB_DIR" \
    --format json \
    --severity CRITICAL,HIGH,MEDIUM,LOW \
    --ignore-unfixed \
    "$IMAGE" 2>/dev/null) || { echo "[SKIP] $IMAGE not found"; continue; }

  # Extract per-severity counts
  python3 -c "
import sys, json
try:
    r = json.loads('''$SCAN_JSON'''.replace(chr(39), chr(39)))
    for sev in ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']:
        count = sum(1 for res in r.get('Results', [])
                    for v in res.get('Vulnerabilities', [])
                    if v.get('Severity') == sev)
        top = [v.get('VulnerabilityID', '') for res in r.get('Results', [])
               for v in res.get('Vulnerabilities', [])
               if v.get('Severity') == 'CRITICAL'][:5]
        print(f'{sev}:{count}:' + ','.join(top))
except Exception as e:
    print(f'CRITICAL:0:')
" 2>/dev/null | while IFS=':' read -r severity count top_cves; do
    curl -s -X POST "$CK_HOST" \
      -H "Content-Type: text/plain" \
      --data-binary "INSERT INTO infra.image_vulnerabilities FORMAT JSONEachRow {
        \"image_name\": \"$(echo "$IMAGE" | cut -d: -f1)\",
        \"image_tag\": \"$(echo "$IMAGE" | cut -d: -f2)\",
        \"scanned_at\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
        \"severity\": \"$severity\",
        \"count\": ${count:-0},
        \"top_cves\": \"$top_cves\",
        \"scanner\": \"trivy\"
      }" --max-time 5 2>/dev/null || true
  done
done
```

### 9.4 Cron Setup

Add to each boss container:

```bash
# Daily at 06:00 UTC — collect image ages
echo "0 6 * * * root /usr/local/bin/collect-image-ages.sh" > /etc/cron.d/image-ages

# Daily at 06:30 UTC — check base image drift
echo "30 6 * * * root /usr/local/bin/check-base-drift.sh" > /etc/cron.d/base-drift

# Daily at 07:00 UTC — vulnerability scan (super-boss only)
echo "0 7 * * * root /usr/local/bin/scan-images.sh" > /etc/cron.d/image-scans
```

---

## 10. Alerting

### 10.1 Alert Rules

| Rule | Condition | Severity | Channel | Response |
|------|-----------|----------|---------|----------|
| Base image too old | `kyb-base` age > 30 days | P2 | Feishu infra channel | Schedule `kyb build` |
| Base image drift | `ubuntu:24.04` drift > 14 days | P2 | Feishu infra channel | `docker pull ubuntu:24.04` |
| Critical CVE | CRITICAL count > 0 on `kyb-base` or `ubuntu:24.04` | **P1** | Feishu @all | Rebuild immediately |
| High CVE threshold | HIGH count > 25 on `kyb-base` | P2 | Feishu infra channel | Schedule rebuild within 7 days |
| Third-party image stale | Age > 90 days without pull | P3 | Feishu infra channel | Schedule pull + restart |
| Upstream security advisory | CVE with known PoC affecting any infra service | **P1** | Feishu @all + TTS | Manual assessment + patch |
| Scan pipeline down | No scan results for `kyb-base` in > 48h | P2 | Feishu infra channel | Check Trivy / cron |

### 10.2 Alert Queries

**Image age alert:**

```sql
-- Find images exceeding policy max_age
SELECT
    ia.image_name,
    ia.image_tag,
    ia.age_days,
    fp.max_age_days,
    ia.cluster
FROM infra.image_ages AS ia
ANY LEFT JOIN infra.image_freshness_policy AS fp
    ON ia.image_name = fp.image_name
    AND ia.image_tag = fp.image_tag
WHERE ia.age_days > fp.max_age_days
  AND ia.collected_at >= now() - INTERVAL 1 DAY
ORDER BY ia.age_days DESC
```

**Base image drift alert:**

```sql
SELECT
    ia.image_name,
    ia.base_image,
    ia.base_image_drift_days,
    fp.max_drift_days
FROM infra.image_ages AS ia
ANY LEFT JOIN infra.image_freshness_policy AS fp
    ON ia.image_name = fp.image_name
WHERE ia.base_image_drift_days > fp.max_drift_days
  AND ia.collected_at >= now() - INTERVAL 1 DAY
```

**Critical CVE alert:**

```sql
SELECT
    image_name,
    image_tag,
    count,
    top_cves,
    scanned_at
FROM infra.image_vulnerabilities
WHERE severity = 'CRITICAL'
  AND count > 0
  AND scanned_at >= now() - INTERVAL 1 DAY
ORDER BY count DESC
```

### 10.3 Alert Fatigue Prevention

| Guard | Implementation |
|-------|---------------|
| Age alert only if image is in use | `WHERE in_use = true` filters out dangling images |
| CVE alert suppression for decommissioned images | Exclude images not referenced by any container or compose file |
| Age alert debounce | Alert only if condition persists for 2 consecutive daily checks |
| CVE known-false-positive filter | Maintain a `cve_ignored` table for CVEs that don't apply (e.g., kernel vulns in containers) |
| Post-rebuild grace period | Suppress age alerts for 48h after a rebuild |

---

## 11. Grafana Dashboard

### Panel 1: Image Age Overview (Table)

- Query: `SELECT cluster, image_name, image_tag, age_days, base_image, base_image_age_days, in_use, rebuild_pending FROM infra.image_ages WHERE collected_at >= now() - INTERVAL 1 DAY ORDER BY age_days DESC`
- Columns: Cluster, Image, Tag, Age (days), Base Image, Base Age (days), In Use, Rebuild Needed
- Conditional formatting: age > 30 = red, 14-30 = yellow, < 14 = green
- `rebuild_pending = true` = bold red indicator

### Panel 2: Age Distribution (Bar Chart)

- X-axis: image_name (grouped)
- Y-axis: age_days
- Color by cluster
- Overlay: policy max_age_days as a dashed threshold line
- Purpose: quickly see which images are oldest across clusters

### Panel 3: Base Image Drift (Time Series)

- Metric: `base_image_drift_days` per base image
- Filter: non-null drift values
- Purpose: track how far behind upstream our cached base images are

### Panel 4: Vulnerability Summary (Single Stat / Gauge)

- Top row: CRITICAL count (threshold > 0 = red)
- Second row: HIGH count (threshold > 25 = red, > 10 = yellow)
- Per-image drill-down via variable selector

### Panel 5: CVE Trend (Time Series)

- X-axis: scanned_at (daily)
- Y-axis: count per severity (stacked)
- Filter by image_name
- Purpose: see if vulnerability counts are increasing or stable

### Panel 6: Top CVEs (Table)

- Query: `SELECT image_name, top_cves FROM infra.image_vulnerabilities WHERE severity = 'CRITICAL' AND count > 0 AND scanned_at >= now() - INTERVAL 2 DAY`
- Columns: Image, Top CVEs (clickable links to NVD/MitRE)
- Purpose: immediate action list for P1 alert response

### Panel 7: Policy Compliance (Stat grid)

- One stat per image showing: `age_days / max_age_days` as a percentage
- Green < 50%, Yellow 50-80%, Red > 80%
- Purpose: compliance dashboard for update policy

---

## 12. Rollout Plan

### Phase 1: Collection Infrastructure (Day 1)

1. Create ClickHouse tables on central CK (Mac/Orbstack).
2. Deploy `collect-image-ages.sh` to super-boss (Mac).
3. Verify data ingests after next cron run.

### Phase 2: Drift Detection (Day 1-2)

1. Deploy `check-base-drift.sh` to super-boss.
2. Manually pull and verify upstream base image timestamps.
3. Validate drift detection against known-stale `ubuntu:24.04`.

### Phase 3: Vulnerability Scanning (Day 2)

1. Install Trivy on super-boss (Mac/Orbstack boss container).
2. Deploy `scan-images.sh`.
3. Run initial scan on all key images.
4. Store results in `infra.image_vulnerabilities`.
5. Review initial CVE findings, build `cve_ignored` list for false positives.

### Phase 4: Tag Versioning (Day 2-3)

1. Modify `lib/kyb/docker.rb` to produce date-stamped tags (`kyb-base:YYYYMMDD`).
2. Modify `lib/kyb/docker.rb` to add `kyb.build-date` label.
3. Run `kyb build` to produce the first versioned tag set.
4. Verify rollback procedure works with versioned tags.

### Phase 5: Alerts + Dashboard (Day 3)

1. Configure `infra.image_freshness_policy` table.
2. Wire alert queries into patrol / cc-connect for Feishu delivery.
3. Build Grafana dashboard panels.
4. Test with deliberately stale image (set low max_age, verify alert fires).

### Phase 6: Policy Enforcement (Day 3-7)

1. Establish rebuild cadence: weekly `kyb build` as baseline (upstream ubuntu:24.04 cadence).
2. Add `kyb build --check` command that checks image age and CVE status before building.
3. Integrate into pre-flight check (`kyb preflight`): warn if base image is stale.
4. Document in CLAUDE.md: agent should check image age before starting work.

---

## Verdict

**Design is sound for implementation.** The monitoring infrastructure mirrors existing patterns (CK ingestion, cron collection, Grafana dashboard). The key additions are:

1. **Age tracking**: Simple `docker inspect` + CK reporting. Zero new dependencies.
2. **Vulnerability scanning**: Requires Trivy installation on super-boss. ~30MB binary, fast scans.
3. **Tag versioning**: 3-line Ruby change in `lib/kyb/docker.rb`. Minimal risk, high value for rollback.
4. **Update policy**: Conservative thresholds (30-day max age for `kyb-base`, 14-day drift for `ubuntu:24.04`). Can be tightened after baseline is established.

The highest-value immediate action is enabling date-stamped tags on `kyb build` -- this costs nothing and enables rollback. Second priority is the initial vulnerability scan to establish the current CVE baseline.

> ／人◕ ‿‿ ◕人＼
