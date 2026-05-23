---
decision: 稍后做
---

# Container Image Vulnerability Tracking

> **Status:** Design Document
> **Date:** 2026-05-23
> **Scope:** Automated vulnerability scanning for all container images used in kyb infra (sandbox image, base infra images, sidecar images), with severity tracking, fix age monitoring, and alerting.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Scope: Images to Scan](#2-scope-images-to-scan)
3. [Scan Tool Selection](#3-scan-tool-selection)
4. [Scan Triggers & Frequency](#4-scan-triggers--frequency)
5. [Data Model](#5-data-model)
6. [Pipeline Architecture](#6-pipeline-architecture)
7. [Dashboard Panels](#7-dashboard-panels)
8. [Alert Rules](#8-alert-rules)
9. [Remediation Workflow](#9-remediation-workflow)
10. [Edge Cases](#10-edge-cases)

---

## 1. Problem Statement

### Current State

kyb operates ~30 container images across 3 clusters: the main sandbox image (built from `Dockerfile`, `ubuntu:24.04`), infra service images (PG, Redis, Kafka, ClickHouse, Grafana, Vector, sing-box), and sidecar exporter images. All are pulled from Docker Hub or public registries.

Today there is:

- **No automated scanning** -- images are never scanned for CVEs after initial selection.
- **No vulnerability tracking** -- no database of known CVEs per image, no severity breakdown.
- **No fix age tracking** -- when a CVE is announced, there is no record of how long the image remained vulnerable before a fix was deployed.
- **No alerting** -- critical CVEs in deployed images go unnoticed indefinitely.
- **Registry cache** (`docs/infra/handbook/registry-cache-deploy.md`) caches images locally but does not inspect them.

### Why track it

| Concern | Impact |
|---------|--------|
| **Ubuntu base drift** | `apt-get upgrade -y` in the sandbox Dockerfile runs at build time. Between builds, the base image accumulates unpatched CVEs. No one knows how many. |
| **Infra image pinning** | PG, Redis, Kafka, etc. are pinned to major versions (e.g., `postgres:16`) but not to specific digests. Docker tags float, silently introducing new vulnerabilities. |
| **Sidecar images** | Images like `timberio/vector:0.42-alpine` and `prometheuscommunity/postgres-exporter:latest` use `latest` tags with no version pinning. These drift silently. |
| **Regression on upgrade** | When an image is updated to fix CVEs, new CVEs may be introduced. Without a baseline scan, regressions are invisible. |
| **Incident response gap** | When a critical CVE is announced (e.g., Log4j, runc), there is no way to answer "which of our images are affected and have we fixed them?" |

### Goals

1. **Every image scanned** -- at build time and on a recurring schedule.
2. **Vulnerability database** -- all findings in ClickHouse for querying, dashboarding, alerting.
3. **Fix age tracking** -- time from CVE publication to image remediation for each image.
4. **CI gates** -- optional: block builds with critical CVEs above a configurable threshold.
5. **Self-service query** -- `kyb vuln list` or direct SQL to answer "what CVEs affect us right now?"

---

## 2. Scope: Images to Scan

### Tier 1: Build-time scan (kyb sandbox image)

The image built from `Dockerfile` (currently `ubuntu:24.04` based). Scanned after every `kyb build`.

| Image | Source | Tag Strategy | Build Frequency |
|-------|--------|-------------|-----------------|
| `kyb-sandbox` | local build | `kyb-sandbox:latest` + date tag | On demand (`kyb build`) |

### Tier 2: Scheduled scan (infra images deployed in production)

All images currently running across the 3 clusters (mac-orbstack, aliyun, office/nuc8).

| Image | Registry | Current Tag | Risk |
|-------|----------|------------|------|
| `postgres:16` | Docker Hub | `16` (floating) | Medium -- minor tag drifts |
| `redis:7` | Docker Hub | `7` (floating) | Medium |
| `clickhouse/clickhouse-server:24.3` | Docker Hub | `24.3` (floating) | Medium |
| `confluentinc/cp-kafka:latest` | Docker Hub | `latest` | High -- no pin |
| `grafana/grafana:latest` | Docker Hub | `latest` | High -- no pin |
| `registry:2` | Docker Hub | `2` (floating) | Low -- minimal attack surface |
| `timberio/vector:0.42-alpine` | Docker Hub | `0.42-alpine` | Low -- pinned minor |
| `prometheuscommunity/postgres-exporter:latest` | Docker Hub | `latest` | High -- no pin |
| `oliver006/redis_exporter:latest` | Docker Hub | `latest` | High -- no pin |
| `danielqsj/kafka-exporter:latest` | Docker Hub | `latest` | High -- no pin |
| `prom/node-exporter:latest` | Docker Hub | `latest` | High -- no pin |
| `otel/opentelemetry-collector-contrib:0.117.0` | Docker Hub | `0.117.0` (pinned) | Low |
| `sing-box` | GitHub / custom | pinned | Low |

### Tier 3: Sidecar images in fleet

Images used by the Vector sidecar pattern (`docs/infra/reviews/sidecar-pattern.md`). Same set as Tier 2 exporter images.

### Image inventory snapshot

Maintain a file `infra/images.txt` (auto-generated or manually curated) that lists every image:tag:digest running across all clusters:

```text
postgres:16@sha256:abc123
redis:7@sha256:def456
clickhouse/clickhouse-server:24.3@sha256:ghi789
...
```

This file serves as the scan input and is version-controlled so scan history is reproducible.

---

## 3. Scan Tool Selection

### Primary: Trivy

[Aqua Security Trivy](https://github.com/aquasecurity/trivy) is the primary scanner.

| Criterion | Trivy | Grype | Docker Scout | Clair |
|-----------|-------|-------|-------------|-------|
| **Install size** | ~20 MB binary | ~15 MB binary | Docker CLI plugin | Server + DB |
| **Scan speed** | ~5-15s per image | ~10-30s per image | ~30-60s (network call) | ~60s+ (server needed) |
| **Offline** | Yes (local DB) | Yes (local DB) | No (requires Docker Hub) | Yes (local DB) |
| **SBOM support** | Syft-based | Built-in | Yes | Plugin |
| **Fix version output** | Yes | Yes | Yes | Yes |
| **Severity granularity** | CRITICAL/HIGH/MEDIUM/LOW/UNKNOWN | Critical/High/Medium/Low/Negligible | Critical/High/Medium/Low | Critical/High/Medium/Low |
| **CVE database** | NVD, GHSA, Alpine, RedHat, etc. | NVD, GHSA, RedHat, etc. | Docker Hub only | NVD, RedHat, Ubuntu |
| **Alpine support** | Full | Full | Full | Partial |
| **Ubuntu support** | Full | Full | Full | Full |

**Why Trivy:**

- Fastest for single-image scans (under 10s for most images).
- Works fully offline once the vulnerability DB is cached -- critical for the sim server with limited bandwidth.
- Supports scanning via image name, tarball, or Docker daemon (no pull needed if image is local).
- Fix version is included in JSON output, enabling fix age computation.
- Single binary, no server component. Can be run from a container or installed on the host.

### Secondary: Grype

Run Grype weekly as a cross-check. Different vulnerability DB sources may catch CVEs Trivy misses. Grype results are stored in the same ClickHouse table with `scanner = 'grype'`.

### Deployment

Trivy runs in a Docker container to avoid installing binaries on the host:

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v trivy-db:/home/trivy/.cache/trivy \
  aquasec/trivy:latest \
  image --format json --severity CRITICAL,HIGH,MEDIUM --output /tmp/scan.json postgres:16
```

For offline clusters (aliyun), the Trivy DB is seeded from the registry cache:

```bash
# Seed DB from registry cache (run on mac-orbstack, copy to sim)
docker run --rm aquasec/trivy:latest image --download-db-only
tar czf trivy-db.tar.gz ~/.cache/trivy/
# Copy to sim and extract to same path (or bind mount volume)
```

On mac-orbstack, Trivy runs directly as a `docker exec` or scheduled container. On aliyun/nuc8, it runs via `ssh` from the boss or as a cron job on the host.

---

## 4. Scan Triggers & Frequency

### Trigger types

| Trigger | Images | Frequency | Tool |
|---------|--------|-----------|------|
| **Build-time** | `kyb-sandbox` | Every `kyb build` | Trivy (inline) |
| **Scheduled daily** | All Tier 2 infra images | Daily at 03:00 CST | Trivy (cron) |
| **Scheduled weekly** | All Tier 2 infra images | Weekly Sunday 04:00 CST | Grype (cross-check) |
| **On deploy** | Any image updated by operator | On `docker pull` + restart | Trivy (boss triggers) |
| **On demand** | Any image | Manual `kyb vuln scan <image>` | Trivy |

### Build-time scan

After `kyb build` completes, the boss (or CI pipeline) runs:

```bash
# Scan the freshly built image
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest \
  image --format json \
  kyb-sandbox:latest \
  > /tmp/vuln-kyb-sandbox.json

# Parse and insert into ClickHouse
# (details in Section 5-6)
```

If the scan finds CRITICAL CVEs above a threshold (default: 0), the build **warns** but does not fail (to avoid blocking work). The operator decides whether to rebuild with a base image update.

### Scheduled daily scan

A cron job on the boss container (or a systemd timer) runs daily:

```bash
#!/bin/bash
# infra/vuln/scan-daily.sh
# Runs at 03:00 CST daily.

IMAGES_FILE="/home/dev/projects/kyb/infra/images.txt"
TRIVY_IMAGE="aquasec/trivy:0.58.0"  # pinned for reproducibility

while IFS= read -r image; do
  echo "Scanning $image..."
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v trivy-db:/home/trivy/.cache/trivy \
    $TRIVY_IMAGE \
    image --format json \
    "$image" \
    > "/tmp/vuln-$(echo $image | tr '/:@' '---').json"
done < "$IMAGES_FILE"

# Parse all results and insert into ClickHouse
ruby /home/dev/projects/kyb/infra/vuln/insert-scans.rb /tmp/vuln-*.json
```

### On-deploy scan

When any infra image is updated (e.g., `docker pull postgres:16 && docker restart`), the boss detects the change via Docker events (`docs/infra/reviews/docker-events.md`) and triggers a scan of the new image digest automatically. This ensures the vulnerability DB is never stale for a running image.

### Database refresh

Trivy's vulnerability DB updates ~hourly from upstream. The scan container pulls the latest DB before each scan run:

```bash
# DB is cached in a named volume; update daily
docker run --rm -v trivy-db:/home/trivy/.cache/trivy aquasec/trivy:latest image --download-db-only
```

On aliyun (offline), the DB is refreshed weekly via the registry cache proxy.

---

## 5. Data Model

### ClickHouse: `image_vulnerabilities`

Raw findings from each scan. One row per (scan_id, image, CVE) combination.

```sql
CREATE TABLE image_vulnerabilities (
    scan_id           UUID,
    scanned_at        DateTime64(3, 'Asia/Shanghai'),
    scanner           LowCardinality(String),      -- 'trivy' or 'grype'
    image_name        String,                      -- e.g., 'postgres'
    image_tag         String,                      -- e.g., '16'
    image_digest      String,                      -- full sha256 digest at scan time
    image_full_ref    String,                      -- e.g., 'postgres:16@sha256:abc...'

    cve_id            String,                      -- e.g., 'CVE-2025-12345'
    package_name      String,                      -- affected package (e.g., 'libssl3')
    package_version   String,                      -- installed version
    fixed_version     String,                      -- version that fixes the CVE (empty if unfixed)
    severity          LowCardinality(String),      -- CRITICAL / HIGH / MEDIUM / LOW / UNKNOWN
    severity_score    Float32,                     -- CVSS score (0-10)
    cve_published_at  Date,                        -- NVD publication date (if available)
    cve_description   String,                      -- brief CVE description
    pkg_type          LowCardinality(String),      -- deb, apk, npm, gem, pip, etc.

    is_fixable        UInt8,                       -- 1 if fixed_version != '', 0 otherwise
    fix_available     UInt8 DEFAULT 0,             -- 1 if a newer image tag could fix this

    _inserted_at      DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(scanned_at)
ORDER BY (scanned_at, image_name, severity, cve_id)
TTL scanned_at + INTERVAL 180 DAY
```

Key design decisions:

- `image_digest` is the key for correlating scans over time. An image tag may float, but the digest is immutable. Two scans of the same digest = same layer = same CVEs (unless the vulnerability DB changed).
- `fixed_version` is nullable. An empty string means no fix exists yet (unfixed 0-day). This is critical for fix age tracking: fix age = time from `cve_published_at` to the scan date where `fixed_version` becomes non-empty.
- `severity_score` is the CVSS score (0-10). Severity labels are mapped from the scanner's output to a canonical set: CRITICAL/HIGH/MEDIUM/LOW/UNKNOWN.
- `is_fixable` is a computed flag for quick filtering.

### ClickHouse: `image_scan_summary`

Each scan run produces a summary row, used for fleet-wide dashboards.

```sql
CREATE TABLE image_scan_summary (
    scan_id           UUID,
    scanned_at        DateTime64(3, 'Asia/Shanghai'),
    scanner           LowCardinality(String),
    image_full_ref    String,
    image_digest      String,

    total_cves        UInt32,
    critical_count    UInt32,
    high_count        UInt32,
    medium_count      UInt32,
    low_count         UInt32,
    fixable_count     UInt32,                      -- CVEs with a known fix
    unfixed_count     UInt32,                      -- CVEs with no fix available
    scan_duration_ms  UInt32,                      -- how long the scan took

    _inserted_at      DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(scanned_at)
ORDER BY (scanned_at, image_full_ref)
```

### ClickHouse: `image_fix_age`

Records the fix event: the moment a particular CVE in a particular image transitioned from unfixed to fixed.

```sql
CREATE TABLE image_fix_age (
    image_name        String,
    image_digest      String,
    cve_id            String,
    cve_published_at  Date,
    first_seen_at     DateTime64(3, 'Asia/Shanghai'),  -- first scan that detected this CVE
    fixed_at          DateTime64(3, 'Asia/Shanghai'),  -- scan date when CVE disappeared (i.e., fixed)
    fix_age_hours     UInt32,                          -- hours between cve_published_at and fixed_at
    image_fix_version String,                          -- image tag/digest post-fix (for rollback audit)

    _inserted_at      DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_inserted_at)
ORDER BY (image_name, cve_id, first_seen_at)
```

`fix_age_hours` is the core metric for "how fast do we remediate?" SLO targets:

| Image Tier | Fix Age SLO (CRITICAL) | Fix Age SLO (HIGH) |
|------------|----------------------|-------------------|
| Sandbox (kyb-sandbox) | 72 hours | 7 days |
| Infra (PG, Redis, etc.) | 72 hours | 7 days |
| Sidecar (exporter, vector) | 7 days | 14 days |

### Derived view: daily vulnerability summary

```sql
CREATE MATERIALIZED VIEW vuln_daily_summary_mv
ENGINE = AggregatingMergeTree()
ORDER BY (date, image_name, severity)
POPULATE
AS SELECT
    toDate(scanned_at) AS date,
    image_name,
    severity,
    uniqExact(cve_id) AS cve_count,
    countIf(is_fixable = 1) AS fixable_count,
    countIf(is_fixable = 0) AS unfixed_count
FROM image_vulnerabilities
GROUP BY date, image_name, severity
```

This powers the daily trend panels.

---

## 6. Pipeline Architecture

### 6.1 Data flow

```
┌─────────────────────────────────────────────────────┐
│                    Scan Pipeline                      │
│                                                      │
│  Trigger ──→ Trivy/Grype ──→ JSON result ──→ Parser │
│    │                    │                 │          │
│    │                    │                 ▼          │
│    │                    │          ┌──────────┐      │
│    │                    └─────────→│  Parser  │      │
│    │                               │ (Ruby)   │      │
│    │                               └────┬─────┘      │
│    │                                    │            │
│    ▼                                    ▼            │
│  ┌─────────┐                    ┌──────────────┐     │
│  │ Triggers│                    │  ClickHouse  │     │
│  │ - build │                    │  (images db) │     │
│  │ - cron  │                    └──────┬───────┘     │
│  │ - event │                           │             │
│  └─────────┘                           ▼             │
│                                   ┌──────────┐       │
│                                   │  Grafana │       │
│                                   │  Dashboards      │
│                                   └──────────┘       │
│                                                      │
│  ┌──────────┐                                        │
│  │ Scanner  │                                        │
│  │ DB Cache │←── Updated daily from upstream         │
│  └──────────┘                                        │
└─────────────────────────────────────────────────────┘
```

### 6.2 Scan pipeline steps

1. **Trigger** fires (cron/build/event/manual).
2. **Pull scanner image** (`aquasec/trivy:0.58.0` pinned version).
3. **Update scanner DB** (download latest vulnerability data from upstream). On offline clusters, skip this step and use cached DB.
4. **Run scan** on target image. Output JSON to temp file with scan metadata (timestamp, trigger, scanner version).
5. **Parse JSON** output into `image_vulnerabilities` and `image_scan_summary` rows.
6. **Compute fix age** by comparing against previous scan results: if a CVE that was present in the previous scan of the same digest is now absent, record a fix event in `image_fix_age`.
7. **Emit Prometheus metrics** (see Section 6.3).
8. **Run alert rules** (see Section 8).
9. **Cleanup** old scan files (retain 7 days for debugging).

### 6.3 Prometheus metrics

Exposed by the scan pipeline for alerting:

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `vuln_scan_duration_seconds` | Histogram | `scanner`, `image` | Time to scan one image |
| `vuln_cve_total` | Gauge | `image`, `severity`, `fixable` | Current CVE count per image |
| `vuln_fix_age_hours` | Gauge | `image`, `cve_id` | Hours since CVE publication to fix |
| `vuln_scan_success` | Counter | `scanner`, `image` | Successful scans |
| `vuln_scan_failure` | Counter | `scanner`, `image`, `error` | Failed scans |
| `vuln_scanner_db_age_hours` | Gauge | `scanner` | Age of local vulnerability DB |

### 6.4 Integration with `kyb` CLI

Extend the `kyb` CLI with vulnerability management commands:

```bash
kyb vuln scan <image>         # Scan a single image (any ref)
kyb vuln scan --all           # Scan all images in infra/images.txt
kyb vuln ls [--severity CRITICAL]  # List current vulnerabilities
kyb vuln ls --image postgres  # List CVEs for a specific image
kyb vuln history <cve-id>     # Show fix history for a CVE across images
kyb vuln dashboard            # Open the Grafana vuln dashboard
```

The CLI calls the same Ruby parsing code used by the cron job, so results always go to ClickHouse.

### 6.5 CI/CD integration

In a GitLab CI pipeline for the sandbox Dockerfile:

```yaml
# .gitlab-ci.yml fragment
vulnerability-scan:
  stage: test
  script:
    - docker build -t kyb-sandbox:$CI_COMMIT_SHA .
    - trivy image --format json --severity CRITICAL,HIGH kyb-sandbox:$CI_COMMIT_SHA > report.json
    - ruby ci/check-vuln-threshold.rb report.json
  artifacts:
    paths: [report.json]
```

The Ruby check script:

```ruby
# ci/check-vuln-threshold.rb
require 'json'

THRESHOLDS = {
  'CRITICAL' => ENV.fetch('VULN_CRITICAL_MAX', 0).to_i,
  'HIGH'     => ENV.fetch('VULN_HIGH_MAX', 5).to_i,
}

data = JSON.parse(File.read(ARGV[0]))
results = data['Results'] || []

severity_counts = Hash.new(0)
results.each do |result|
  (result['Vulnerabilities'] || []).each do |vuln|
    severity_counts[vuln['Severity']] += 1
  end
end

failures = []
THRESHOLDS.each do |severity, max|
  count = severity_counts[severity] || 0
  if count > max
    failures << "#{severity}: #{count} > #{max} (threshold)"
  end
end

if failures.any?
  puts "Vulnerability threshold exceeded:"
  failures.each { |f| puts "  - #{f}" }
  puts severity_counts.sort.map { |s, c| "  #{s}: #{c}" }.join("\n")
  exit 1
else
  puts "Vulnerability scan passed thresholds:"
  puts severity_counts.sort.map { |s, c| "  #{s}: #{c}" }.join("\n")
end
```

---

## 7. Dashboard Panels

### Panel 1: Vulnerability Count by Image (bar chart)

- **Metric**: `vuln_cve_total` by `image`, stacked by `severity`
- **Granularity**: Latest scan per image
- **Purpose:** At-a-glance ranking of which images have the most CVEs. Color = severity (red=CRITICAL, orange=HIGH, yellow=MEDIUM, blue=LOW).
- **ClickHouse query:**
  ```sql
  SELECT
      image_name,
      severity,
      count() as cve_count
  FROM image_vulnerabilities
  WHERE scanned_at = (
      SELECT max(scanned_at) FROM image_vulnerabilities AS sub
      WHERE sub.image_name = image_vulnerabilities.image_name
        AND sub.image_digest = image_vulnerabilities.image_digest
  )
  GROUP BY image_name, severity
  ORDER BY image_name, severity
  ```

### Panel 2: Vulnerability Trend (time series, stacked area)

- **Metric**: `vuln_cve_total` over time by severity, aggregated across all images
- **Granularity**: 1 day buckets
- **Purpose:** See whether the fleet-wide vulnerability posture is improving or degrading over time.
- **ClickHouse query:**
  ```sql
  SELECT
      toDate(scanned_at) AS date,
      severity,
      uniqExact(cve_id) AS cve_count
  FROM image_vulnerabilities
  GROUP BY date, severity
  ORDER BY date
  ```

### Panel 3: Fix Age Distribution (heatmap)

- **X-axis**: Time (1 day buckets)
- **Y-axis**: Fix age buckets (0-6h, 6-24h, 24-72h, 72h-7d, 7d-30d, 30d+)
- **Color**: Count of CVEs fixed in that bucket
- **Purpose:** Visualize remediation speed. If the heatmap shifts toward longer buckets over time, remediation is slowing down.

### Panel 4: Current Critical CVE Table

- **Columns**: `cve_id`, `image_name`, `package`, `severity_score`, `cve_published_at`, `fix_available`, `age_days`
- **Purpose:** List of all currently open CRITICAL CVEs, sorted by age. The action list for the operator.
- **ClickHouse query:**
  ```sql
  SELECT
      cve_id,
      image_name,
      package_name || ':' || package_version AS package,
      severity_score,
      cve_published_at,
      fix_available,
      dateDiff('day', cve_published_at, today()) AS age_days
  FROM image_vulnerabilities
  WHERE scanned_at = (
      SELECT max(scanned_at) FROM image_vulnerabilities
  )
    AND severity = 'CRITICAL'
    AND fix_available = 1
  ORDER BY age_days DESC
  ```

### Panel 5: Fix Age SLO Compliance (stat)

- Per image tier, rolling 30-day fix age P90 vs. SLO target
- Color-coded: green (under SLO), yellow (within 20% of SLO), red (over SLO)
- **Purpose:** At-a-glance, are we fixing fast enough?

### Panel 6: Unfixable CVE Count (stat)

- Count of CVEs with `fix_available = 0` (no fix exists anywhere)
- Trend over time
- **Purpose:** Track exposure to unpatched vulnerabilities. If this number spikes, a new class of 0-days affects the stack.

### Panel 7: CVE Type Breakdown (pie chart)

- Grouped by `pkg_type` (deb, apk, npm, gem, pip, etc.)
- **Purpose:** Identify whether vulnerabilities come from OS packages (deb/apk) or language-level dependencies (npm, pip). Drives remediation strategy (OS update vs. language-level dependency bump).

### Panel 8: Scan Coverage (table)

- **Columns**: `image`, `last_scanned_at`, `scanner_version`, `total_cves`, `status` (OK / STALE)
- **Purpose:** Ensure all images in scope are being scanned. An image is STALE if not scanned in >48 hours.
- **ClickHouse query:**
  ```sql
  SELECT
      image_full_ref,
      max(scanned_at) AS last_scanned_at,
      argMax(total_cves, scanned_at) AS last_cve_count,
      if(max(scanned_at) > now() - INTERVAL 48 HOUR, 'OK', 'STALE') AS status
  FROM image_scan_summary
  GROUP BY image_full_ref
  ORDER BY status, last_scanned_at
  ```

---

## 8. Alert Rules

### P1: Critical CVE in production image

| Field | Value |
|-------|-------|
| **Condition** | `vuln_cve_total{image!="kyb-sandbox", severity="CRITICAL"} > 0` |
| **Duration** | 1 hour (allow time for the automated scan to detect, then page) |
| **Severity** | P1 -- critical |
| **Action** | Notify Feishu vuln channel. Create remediation issue. |
| **Rationale** | A critical CVE in a deployed infra image means the production environment is vulnerable. Immediate remediation required. |

### P2: Fix age SLO breached

| Field | Value |
|-------|-------|
| **Condition** | `vuln_fix_age_hours{image!="kyb-sandbox"} > 72` for fixable CRITICAL CVEs |
| **Duration** | Immediate (at scan time) |
| **Severity** | P2 |
| **Action** | Notify Feishu vuln channel. Escalate to image owner. |
| **Rationale** | A fix has been available for >72 hours but not deployed. The fix window has closed. |

### P2: New CRITICAL CVE detected during build

| Field | Value |
|-------|-------|
| **Condition** | Scan pipeline detects a new CRITICAL CVE on `kyb-sandbox:latest` that was not present in the previous scan of the previous image |
| **Duration** | Immediate |
| **Severity** | P2 |
| **Action** | Notify Feishu vuln channel with the CVE details and the base image version. |
| **Rationale** | A new CVE was introduced by a base image update or package installation. The operator should evaluate whether to roll back or patch. |

### P2: Scan failure

| Field | Value |
|-------|-------|
| **Condition** | `vuln_scan_failure > 2` in the last hour |
| **Duration** | 5 minutes |
| **Severity** | P2 |
| **Action** | Investigate scanner container, disk space, network. |
| **Rationale** | If scanning fails, vulnerability data goes stale. Blind spot grows. |

### P3: Scanner DB too old

| Field | Value |
|-------|-------|
| **Condition** | `vuln_scanner_db_age_hours > 48` |
| **Duration** | Immediate |
| **Severity** | P3 |
| **Action** | Refresh scanner DB (or investigate network issues on offline clusters). |
| **Rationale** | An old DB may miss recent CVEs. False sense of security. |

### P3: Image not scanned in 48 hours

| Field | Value |
|-------|-------|
| **Condition** | `vuln_scan_success{image="...", scanner="trivy"}` last value older than 48h for any image |
| **Duration** | Immediate |
| **Severity** | P3 |
| **Action** | Check cron schedule, boss health, Docker daemon state. |
| **Rationale** | The scan pipeline may have stalled. Ensure coverage is restored. |

---

## 9. Remediation Workflow

### 9.1 Automated: Base image refresh

For the `kyb-sandbox` image built from `ubuntu:24.04`, the most common fix is to rebuild:

```bash
# Trigger a rebuild (automatically picks up latest ubuntu:24.04 packages)
kyb build

# Scan the new image
kyb vuln scan kyb-sandbox:latest

# Compare with previous scan
kyb vuln diff kyb-sandbox:prev-digest kyb-sandbox:latest
```

If `kyb build` is triggered by the vuln alert, the flow is:

1. Alert fires: `CRITICAL CVE in kyb-sandbox`
2. Boss auto-triggers `kyb build` (unless operator intervenes)
3. New image is scanned
4. If the CVE is fixed (no longer in scan results), fix age is recorded, alert resolves
5. If the CVE persists (fix not yet in Ubuntu repos), re-alert after 24h

### 9.2 Semi-automated: Infra image digest pin update

For infra images with floating tags (e.g., `postgres:16`):

1. Alert: `CRITICAL CVE in postgres:16 (CVE-2025-XXXXX, fix available)`
2. Pull latest digest: `docker pull postgres:16` (gets the latest `16`-tagged image)
3. Re-scan: `kyb vuln scan postgres:16`
4. Compare digests:
   - If digest changed and CVE is gone: update `images.txt`, restart container
   - If digest changed but CVE persists: flag for manual intervention (core image issue)
   - If digest unchanged: upstream tag not updated yet, set a watch
5. Container restart: `docker compose up -d postgres-16` or `docker restart kyb-infra-pg16`

### 9.3 Manual: Unfixable CVE

CVEs with no fix available (`fix_available = 0`) are tracked separately:

- If the affected package is unused: remove it from the image
- If the affected package is critical: evaluate mitigations (network isolation, seccomp, AppArmor)
- If the CVE is in a base image (e.g., kernel in ubuntu:24.04): the host kernel is unaffected (container shares host kernel); this is a false positive for container scanning and should be marked as ignored

### 9.4 CVE ignore list

Maintain an `infra/vuln/ignored-cves.json` file for CVEs that are known false positives or accepted risks:

```json
{
  "ignored": [
    {
      "cve_id": "CVE-2025-NOPE",
      "reason": "Kernel CVE, not relevant in container context (shares host kernel)",
      "images": ["*"],
      "expires": "2026-06-01"
    },
    {
      "cve_id": "CVE-2025-EXAMPLE",
      "reason": "Affects unused feature, fix pending upstream. Accepting risk.",
      "images": ["postgres:16"],
      "expires": "2026-07-01",
      "owner": "@kyb-ops"
    }
  ]
}
```

Ignored CVEs are filtered out at the parser stage and not inserted into ClickHouse. Expired ignores trigger a re-evaluation alert.

### 9.5 Fix age tracking algorithm

```ruby
# infra/vuln/fix_age_tracker.rb (conceptual)

class FixAgeTracker
  def process(scan_result, previous_scans)
    current_cves = scan_result.cves_by_image_digest
    previous_scan = previous_scans.first  # most recent prior scan of same image:digest

    if previous_scan.nil?
      # First scan of this digest; no fix events to record
      return []
    end

    previous_cves = previous_scan.cves_by_image_digest
    now_fixed = previous_cves.keys - current_cves.keys

    now_fixed.map do |cve_id|
      prev = previous_cves[cve_id]
      {
        image_name: scan_result.image_name,
        image_digest: scan_result.image_digest,
        cve_id: cve_id,
        cve_published_at: prev.cve_published_at,
        first_seen_at: prev.scanned_at,
        fixed_at: scan_result.scanned_at,
        fix_age_hours: (scan_result.scanned_at - prev.cve_published_at) / 3600,
        image_fix_version: scan_result.image_digest
      }
    end
  end
end
```

The fix age is measured from `cve_published_at` (NVD publication date), not from `first_seen_at`, because:
- The CVE may have been published several days before the image was first scanned
- The true "time to remediate" starts when the CVE becomes known, not when we happen to scan
- `first_seen_at` is recorded in `image_fix_age` for diagnostic purposes but `fix_age_hours` uses `cve_published_at`

---

## 10. Edge Cases

### First scan with no baseline

When the scan pipeline is first deployed, there is no previous scan to compare against. All CVEs are "new." Mitigation:

- Insert baselines with `first_seen_at = scanned_at` (no fix events triggered)
- After the second scan, the diff algorithm works normally
- A "grace period" flag suppresses fix age alerts for the first 24 hours after pipeline deployment

### Image deleted from registry

If an image is pulled from Docker Hub (e.g., old version removed) and also not cached locally, scanning fails. Mitigation:

- Keep the last scan result in ClickHouse (never delete)
- Mark the image as `status = "UNAVAILABLE"` in `image_scan_summary`
- Alert if an image is unavailable for >7 days (may indicate a breaking change upstream)

### Scanner version mismatch

When Trivy releases a new major version, vulnerability detection may change (more/fewer CVEs detected). Mitigation:

- Pin Trivy version (`aquasec/trivy:0.58.0` for the stable pipeline)
- Run a parallel scan with the new version for 7 days before switching
- Store `scanner` and scanner version in every scan record for auditability
- When switching versions, document the delta in detected CVEs

### CVE retraction or downgrade

Sometimes a CVE is retracted or its severity is downgraded by NVD. Mitigation:

- Trivy DB updates reflect this; the next scan will not include the retracted CVE
- The CVE disappears from the current scan results, triggering a fix event with `fix_age_hours` from publication to retraction
- This is actually correct behavior (retraction = fixed from informational standpoint)

### Offline cluster (aliyun)

Aliyun (sim) has limited network access. The scan pipeline must work without direct internet:

1. **Trivy DB**: Downloaded on mac-orbstack, copied to aliyun via rsync over Tailscale or via the registry cache proxy. The DB file is ~500 MB.
2. **Image availability**: All images should be cached in the local registry cache (`registry-cache-deploy.md`). If not cached, scanning fails with `image not found`.
3. **ClickHouse**: aliyun writes to the central ClickHouse on mac-orbstack (if network is up) or to a local ClickHouse (if offline). The local CK is synced when connectivity is restored.

### Image with no known CVEs (base distroless)

If an image has zero CVEs (e.g., `gcr.io/distroless/static`), the Trivy JSON output contains an empty `Vulnerabilities` array. The parser handles this gracefully:

```ruby
# In the parser
vulns = result.dig('Vulnerabilities') || []  # nil-safe
```

### Scanning the same image digest twice

If the same image digest is scanned twice (e.g., cron hits an unmodified image), the second scan should not produce duplicate rows. Mitigation:

- Use `ReplacingMergeTree` on `image_vulnerabilities`
- Dedup key: `(scan_id, image_digest, cve_id)` -- the latest `scanned_at` wins
- The fix age logic in `FixAgeTracker` detects no diff between scans and produces no new fix events

### Race condition: scan in progress while new image deployed

If a deploy and a cron scan happen simultaneously, the scan may pick up the old image digest. This is fine:

- The scan result is stored with the old digest
- The deploy triggers a separate on-deploy scan for the new digest
- Both results exist in ClickHouse; the dashboard always shows the latest per image name

---

## Appendix A: Implementation Phases

### Phase 0: Foundation (2-3 days)

1. Deploy Trivy as a Docker container (`kyb-infra-trivy`)
2. Create `infra/images.txt` with all current image:tag:digest entries
3. Create ClickHouse tables: `image_vulnerabilities`, `image_scan_summary`, `image_fix_age`
4. Write the Ruby scan parser (`infra/vuln/parse-scan.rb`)
5. Run first manual scan of `kyb-sandbox:latest` and all infra images
6. Create `infra/vuln/ignored-cves.json` with initial false positives

### Phase 1: Scheduled scanning (2-3 days)

7. Add daily scan cron to the boss container
8. Create `infra/vuln/scan-daily.sh` script
9. Wire scan results into ClickHouse via the parser
10. Create `image_scan_summary` MV

### Phase 2: Fix age tracking (2 days)

11. Implement `FixAgeTracker` in Ruby
12. Populate `image_fix_age` on each scan
13. Backfill fix age for existing CVE history (if any)

### Phase 3: Dashboards (2 days)

14. Build 8 Grafana panels listed in Section 7
15. Create Grafana dashboard `Container Vulnerability Report`
16. Add to existing infra dashboard catalog

### Phase 4: Alerts (2 days)

17. Configure 6 alert rules in Grafana / Alertmanager
18. Wire to Feishu notification channel
19. Create `kyb vuln` CLI subcommands

### Phase 5: CI/CD integration (2 days)

20. Add vulnerability scan stage to GitLab CI
21. Create threshold check script
22. Document in CLAUDE.md and developer workflow

## Appendix B: Storage Estimates

| Data | Daily Volume | 90-Day Total |
|------|-------------|--------------|
| `image_vulnerabilities` | ~200 KB (15 images x ~100 CVEs each) | ~18 MB |
| `image_scan_summary` | ~5 KB | ~450 KB |
| `image_fix_age` | ~1 KB | ~90 KB |
| Trivy DB (cached) | ~500 MB (one-time, refreshed daily) | ~500 MB (auto-updates in place) |
| Scan JSON artifacts | ~500 KB per full scan run | ~45 MB (retain 7 days) |

## Appendix C: Related Documents

- Docker registry cache: `docs/infra/handbook/registry-cache-deploy.md`
- Multi-cluster architecture: `docs/infra/multi-cluster-boss-architecture.md`
- Docker events monitoring: `docs/infra/reviews/docker-events.md`
- Alert fatigue reduction: `docs/infra/reviews/alert-fatigue.md`
- Error budget tracking: `docs/infra/reviews/error-budget.md`
- Sidecar pattern for observability: `docs/infra/reviews/sidecar-pattern.md`

---

> /人◕ ‿‿ ◕人＼
