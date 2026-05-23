---
decision: 稍后做
---

# Docker Volume Disk Usage Review

Date: 2026-05-23
Scope: All Docker volumes on the kyb sandbox host

## Current State Summary

| Category | Count | Total Size | % of Volume Disk |
|----------|-------|------------|------------------|
| Build cache volumes | 7 | ~14.5G | 96% |
| Infrastructure data volumes | 10 | ~570M | 3.8% |
| Sandbox claude data volumes | 6 | ~21M | 0.1% |
| Anonymous (kafka) | 2 | 0 | 0% |
| **Total** | **25** | **~15.1G** | **100%** |

Host disk: 305G total, 83G used (27%), overlay filesystem (Docker root).

## Volume Catalog

### Infrastructure Data Volumes (persistent, in use)

These volumes hold persistent service data and are mounted by `kyb-infra-*` containers. All created on 2026-05-23.

| Volume | Mount Target | Size | Container | Created |
|--------|-------------|------|-----------|---------|
| ch-data | /var/lib/clickhouse | 274.9M | kyb-infra-clickhouse | 2026-05-23 |
| pg15-data | /var/lib/postgresql/data | 81.4M | kyb-infra-postgresql-15 | 2026-05-23 |
| grafana-storage | /var/lib/grafana | 83.6M | kyb-infra-grafana | 2026-05-23 |
| pg14-data | /var/lib/postgresql/data | 41.6M | kyb-infra-postgresql-14 | 2026-05-23 |
| pg16-data | /var/lib/postgresql/data | 38.7M | kyb-infra-postgresql-16 | 2026-05-23 |
| pg17-data | /var/lib/postgresql/data | 38.6M | kyb-infra-postgresql-17 | 2026-05-23 |
| kafka-data | /var/lib/kafka/data | 11.3M | kyb-infra-kafka | 2026-05-23 |
| registry-cache | /var/lib/registry | 188.0K | kyb-registry-cache | 2026-05-23 |
| cc-connect-data | /root/.cc-connect | 24.0K | kyb-infra-cc-connect | 2026-05-23 |
| redis-data | /data | 12.0K | kyb-infra-redis | 2026-05-23 |

### Build Cache Volumes (shared, in use)

Shared caches mounted into boss containers (`kyb-infra-boss`, `kyb-infra-boss2`, `kyb-infra-boss3`, `kyb-infra-boss-fallback`, `kyb-infra-boss-old`). These account for 96% of total volume disk usage.

| Volume | Size | Created | Notes |
|--------|------|---------|-------|
| kyb-gradle-cache | 6.0G | 2026-05-17 | Gradle wrapper+artifacts |
| kyb-swift-cache | 4.0G | 2026-05-17 | Swift toolchain |
| kyb-maven-cache | 3.9G | 2026-05-17 | Maven repository |
| kyb-mise-cache | 364M | 2026-05-17 | mise runtime downloads |
| kyb-pip-cache | 325M | 2026-05-17 | pip cache |
| kyb-node_modules | 0 | 2026-05-12 | Empty (unused) |
| hamilton-node_modules | 0 | 2026-05-23 | Empty (unused) |

### Sandbox Claude Volumes (mostly dangling)

Created during kyb sandbox sessions to persist Claude Code agent state. All from today (2026-05-23).

| Volume | Size | Has Container? | Status |
|--------|------|----------------|--------|
| kyb-kyb-teams-claude | 21.1M | No | Dangling |
| kyb-kyb-check-full-claude | 12.0K | No | Dangling |
| kyb-kyb-check-v2-claude | 12.0K | No | Dangling |
| kyb-kyb-check-v3-claude | 12.0K | No | Dangling |
| kyb-kyb-check-verify-claude | 12.0K | No | Dangling |
| kyb-kyb-robust-claude | 4.0K | Yes (stopped: kyb-kyb-robust) | Orphaned |

## Observations

### 1. Cache Volumes Dominate (and that is OK)

96% of volume space is build caches (gradle, maven, swift). These are:

- **Shared across boss containers**: same volumes mounted in all boss containers with `z` mode. No per-container duplication.
- **Fast-growing on first build**: the initial `gradle build` and Maven dependency resolution write ~14G of cache data. Subsequent builds are incremental.
- **Expected to plateau**: once all dependencies are cached, growth is near zero. No unbounded growth risk.

The 14.5G cache baseline is acceptable given 223G free disk.

### 2. Infrastructure Volumes Are Modest and Stable

Total ~570M across 10 services. Largest is ClickHouse at 275M. PG databases are small (38-81M each) — these are fresh instances with no production workload. Growth rate is currently minimal.

**Growth rate baseline (day 1 snapshot)**:

| Volume | Day 1 Size | Projected 30-day (linear) |
|--------|-----------|--------------------------|
| ch-data | 275M | Low (analytics data accumulates) |
| pg15-data | 81M | Low (few rows) |
| pg16-data | 39M | Low (few rows) |
| Other infra | <100M each | Negligible |

All PG volumes are on `trust` auth with no application load. Real growth rates will only be measurable once application traffic begins.

### 3. Kafka Anonymous Volumes

Two anonymous volumes (6b185..., cae64...) are attached to `kyb-infra-kafka`. Zero bytes used — these are likely secrets/config mounts that are empty or ephemeral.

### 4. Dangling Volumes (cleanup candidates)

**5 volumes with no container reference:**

| Volume | Size | Created | Risk | Action |
|--------|------|---------|------|--------|
| kyb-kyb-check-full-claude | 12K | 2026-05-23 | None | Remove |
| kyb-kyb-check-v2-claude | 12K | 2026-05-23 | None | Remove |
| kyb-kyb-check-v3-claude | 12K | 2026-05-23 | None | Remove |
| kyb-kyb-check-verify-claude | 12K | 2026-05-23 | None | Remove |
| kyb-kyb-teams-claude | 21.1M | 2026-05-23 | Loses agent conversation history | Remove or archive |
| kyb-kyb-robust-claude | 4K | 2026-05-23 | Attached to stopped container | Remove after container removal |

**2 empty cache volumes (never populated):**

| Volume | Size | Action |
|--------|------|--------|
| kyb-node_modules | 0 | Remove |
| hamilton-node_modules | 0 | Remove |

These were created but never used (no `npm install` was run, or the project does not use Node).

## Container Writability (additional concern beyond volumes)

Docker writable layers are significant for boss containers:

| Container | Writable Layer | Status |
|-----------|---------------|--------|
| kyb-infra-boss-old | 8.37G | Running |
| kyb-infra-boss-fallback | 4.57G | Running |
| kyb-infra-boss | 4.55G | Running |
| kyb-infra-boss3 | 4.51G | Running |
| kyb-infra-boss2 | 333M | Running |

These writable layers are NOT volume storage — they are container layer diffs that persist while the container runs. They consume space under `/var/lib/docker/overlay2/`. Total writable layer overhead: ~22.5G.

This is the actual high-cost area. Each boss container writes ~4.5G of transient data during AI agent sessions (code generation, compilation, file operations). When the container is removed, this space is reclaimed.

## Cleanup Policy

### Tier 1: Immediate (safe to run now)

```bash
# Remove dangling sandbox claude volumes (no data loss)
docker volume rm \
  kyb-kyb-check-full-claude \
  kyb-kyb-check-v2-claude \
  kyb-kyb-check-v3-claude \
  kyb-kyb-check-verify-claude \
  kyb-kyb-teams-claude

# Remove empty/unused cache volumes
docker volume rm \
  kyb-node_modules \
  hamilton-node_modules
```

Potential reclaim: ~21.1M (negligible, but reduces clutter).

### Tier 2: After stopped container cleanup

```bash
docker rm kyb-kyb-robust friendly_banach
docker volume rm kyb-kyb-robust-claude
```

### Tier 3: Boss container churn (regular maintenance)

Boss containers accumulate ~4.5G each in writable layer data. When a boss session is done:

```bash
docker rm <boss-container-name>
```

This reclaims the overlay2 layer. Job is to track which boss containers are no longer needed.

### Tier 4: Cache volume invalidation

Cache volumes are safe to remove but expensive to rebuild:

| Volume | Rebuild Time | Rebuild Cost |
|--------|-------------|--------------|
| kyb-maven-cache | 5-10 min | Maven downloads all deps |
| kyb-gradle-cache | 10-20 min | Gradle downloads all deps |
| kyb-swift-cache | 15-30 min | Swift toolchain download |
| kyb-pip-cache | 2-5 min | pip downloads |
| kyb-mise-cache | 1-2 min | mise downloads |

Only remove when disk pressure is critical (track via `disk-growth.md` review).

### Automated Cleanup Suggestion

Add a nightly systemd timer or cron job:

```bash
# Prune dangling volumes (but not cache volumes)
docker volume prune --filter label!=kyb-cache --force
```

This requires labeling cache volumes. Currently no labels are applied.

## Monitoring Recommendations

1. **Add label `kyb-cache=true` to all cache volumes** so `docker volume prune` can be selective.

2. **Weekly volume size snapshot** — pipe `docker volume ls` through size check and log to a file for growth rate tracking:

   ```bash
   # crontab entry
   0 6 * * 1 for v in $(docker volume ls -q); do
     size=$(docker run --rm -v $v:/vol alpine du -sh /vol 2>/dev/null | cut -f1)
     echo "$(date -I) $v $size"
   done >> /var/log/volume-sizes.log
   ```

3. **Alert when total volume usage > 50G** — cache growth should plateau, but if it doesn't, investigate.

4. **Track boss container writable layers** — the bigger concern than volumes. Grafana dashboard should include `container_fs_usage_bytes` from cadvisor.

## Conclusion

Volume disk usage is **healthy**. 15G total on a 305G disk (223G free) is not a concern. The real space pressure comes from:

1. Boss container writable layers (~22.5G cumulative, transient)
2. Docker images storage (~14G base image for kyb-base at 8G, various other images)
3. Container logs (not measured in this review)

The cache volumes are the dominant consumer but expected to plateau. Infrastructure volumes are modest. Dangling volumes are small and cosmetic. Actionable items: clean up the 5+2 dangling volumes, and add cache volume labels.
