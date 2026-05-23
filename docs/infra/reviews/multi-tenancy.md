---
decision: 稍后做
---

# Multi-Tenancy Isolation Monitoring

**Date**: 2026-05-23
**Scope**: Per-project resource usage tracking, namespace isolation verification, and access audit logging across kyb-managed sandbox infrastructure.

---

## 1. Background

kyb manages sandbox containers for multiple projects and users on shared infrastructure (mac-orbstack, aliyun, office clusters). Each sandbox is ostensibly isolated by Docker, but without monitoring we cannot answer basic multi-tenancy questions:

| Question | Impact |
|----------|--------|
| Which project is consuming the most CPU/memory/disk? | Capacity planning, fair-share enforcement |
| Are any containers escaping their resource limits? | Noise-neighbor prevention, SLA protection |
| Can container A reach container B's network? | Isolation verification, security audit |
| Who accessed which sandbox and when? | Incident response, compliance logging |
| Are stale containers accumulating on shared hosts? | Disk exhaustion, resource leak detection |
| Do any containers share host volumes they should not? | Data confidentiality boundary verification |

This document defines the monitoring pipeline to track these dimensions in real time and retrospectively.

### 1.1 Tenancy Model

```
Cluster (mac-orbstack / aliyun / office)
 ├── Project A (e.g. kyb)
 │    ├── sandbox: infra-boss
 │    ├── sandbox: kyb-fix-init-flag
 │    └── sandbox: kyb-feat-xxx
 ├── Project B (e.g. cc-connect)
 │    ├── sandbox: cc-connect-main
 │    └── sandbox: cc-connect-staging
 └── System services (postgres, redis, clickhouse, grafana, kafka)
      ├── shared-pg-16
      ├── shared-redis
      └── shared-clickhouse
```

Each sandbox belongs to exactly one **project**. Projects are **tenants**. System services are shared infrastructure — their access must also be audited per-tenant.

---

## 2. Data Sources

### 2.1 Docker Container Labels (Source of Truth for Tenancy)

Every kyb-created container is tagged with labels. These are the **primary tenancy dimensions**.

**Source**: Docker API / Events

```json
{
  "container_id": "a1b2c3d4...",
  "labels": {
    "kyb.project": "kyb",
    "kyb.sandbox": "kyb-fix-init-flag",
    "kyb.cluster": "mac-orbstack",
    "kyb.user": "dongqs",
    "kyb.created_at": "2026-05-23T10:00:00Z"
  }
}
```

**Enforcement**: `kyb create` and `kyb did create` MUST set these labels. The CLI already has project/branch context — wire it into `docker run --label`.

### 2.2 Docker Stats (Resource Usage)

Docker's stats API provides per-container resource metrics in real time.

**Source**: `docker stats --no-stream` polled by node-exporter or a dedicated watcher.

```json
{
  "container_id": "a1b2c3d4...",
  "timestamp": "2026-05-23T14:30:00Z",
  "cpu_percent": 12.5,
  "memory_usage_bytes": 268435456,
  "memory_limit_bytes": 1073741824,
  "memory_percent": 25.0,
  "network_rx_bytes": 1048576,
  "network_tx_bytes": 524288,
  "block_read_bytes": 4096,
  "block_write_bytes": 8192,
  "pids": 15
}
```

### 2.3 Docker Events (Lifecycle Audit)

Docker daemon emits events for every container lifecycle change.

**Source**: `docker events --format json` streamed via Vector.

```
container:start    → sandbox created
container:stop     → sandbox stopped
container:die      → sandbox exited/crashed
container:destroy  → sandbox removed
container:exec     → `kyb exec` or `docker exec` invocation
network:connect    → container attached to a network
network:disconnect → container detached from a network
volume:mount       → volume attached
volume:unmount     → volume detached
```

### 2.4 Docker Inspect (Boundary Verification)

Periodic or on-demand inspection of cross-container boundaries.

**Source**: `docker inspect <container>` collected by patrol or audit cron.

```json
{
  "container_id": "a1b2c3d4...",
  "network_mode": "kyb-default",
  "networks": ["kyb-default"],
  "mounts": [
    {"source": "/home/dongqs/.ssh", "destination": "/home/dev/.ssh", "mode": "ro"},
    {"source": "/var/run/docker.sock", "destination": "/var/run/docker.sock", "mode": "rw"}
  ],
  "cap_add": [],
  "privileged": false,
  "port_bindings": {}
}
```

### 2.5 Docker Disk Usage (System-Level)

Per-container disk usage for overlay2 and volume mounts.

**Source**: `docker system df --verbose` polled periodically.

```json
{
  "container_id": "a1b2c3d4...",
  "image_size_bytes": 2147483648,
  "container_disk_bytes": 104857600,
  "volume_mounts": [
    {"name": "kyb-ssh", "size_bytes": 4096},
    {"name": "kyb-data", "size_bytes": 52428800}
  ]
}
```

### 2.6 kyb Logs (User Action Audit)

`kyb exec/enter/stop/start/rm` commands recorded with user identity.

**Source**: `kyb` CLI stdout/stderr piped to Vector or syslog.

```
[2026-05-23 14:30:00] [INFO] [kyb] user=dongqs action=exec sandbox=kyb-fix-init-flag cmd="npm test" exit_code=0
[2026-05-23 14:31:00] [INFO] [kyb] user=dongqs action=enter sandbox=infra-boss duration=45m
```

---

## 3. ClickHouse Schema

### 3.1 `infra.container_stats` — Resource Usage Time-Series

```sql
CREATE TABLE IF NOT EXISTS infra.container_stats (
  timestamp DateTime64(3) CODEC(ZSTD(1)),
  cluster LowCardinality(String),
  project LowCardinality(String),
  sandbox LowCardinality(String),
  container_id FixedString(12),
  user LowCardinality(String),
  cpu_percent Float32,
  memory_usage_bytes UInt64,
  memory_limit_bytes UInt64,
  memory_percent Float32,
  network_rx_bytes UInt64,
  network_tx_bytes UInt64,
  block_read_bytes UInt64,
  block_write_bytes UInt64,
  pids UInt16
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (project, timestamp);
```

### 3.2 `infra.container_events` — Lifecycle Audit Log

```sql
CREATE TABLE IF NOT EXISTS infra.container_events (
  timestamp DateTime64(3) CODEC(ZSTD(1)),
  cluster LowCardinality(String),
  project LowCardinality(String),
  sandbox LowCardinality(String),
  container_id FixedString(12),
  user LowCardinality(String),
  event_type LowCardinality(String),      -- start/stop/die/destroy/exec
  exit_code Nullable(UInt16),
  duration_seconds Nullable(UInt32)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp);
```

### 3.3 `infra.container_network` — Isolation Boundary Snapshot

```sql
CREATE TABLE IF NOT EXISTS infra.container_network (
  timestamp DateTime DEFAULT now(),
  cluster LowCardinality(String),
  project LowCardinality(String),
  sandbox LowCardinality(String),
  container_id FixedString(12),
  network_name LowCardinality(String),
  ip_address String,
  peers Nested (
    container_id FixedString(12),
    project LowCardinality(String),
    sandbox LowCardinality(String),
    ip_address String
  )
)
ENGINE = ReplacingMergeTree()
ORDER BY (container_id, network_name);
```

### 3.4 `infra.container_mounts` — Volume/Device Mount Audit

```sql
CREATE TABLE IF NOT EXISTS infra.container_mounts (
  timestamp DateTime DEFAULT now(),
  cluster LowCardinality(String),
  project LowCardinality(String),
  sandbox LowCardinality(String),
  container_id FixedString(12),
  mount_source String,
  mount_destination String,
  mount_mode LowCardinality(String),       -- ro/rw
  mount_type LowCardinality(String)        -- bind/volume/tmpfs
)
ENGINE = ReplacingMergeTree()
ORDER BY (container_id, mount_source);
```

### 3.5 `infra.access_log` — User Action Audit Trail

```sql
CREATE TABLE IF NOT EXISTS infra.access_log (
  timestamp DateTime64(3) CODEC(ZSTD(1)),
  cluster LowCardinality(String),
  project LowCardinality(String),
  sandbox LowCardinality(String),
  container_id FixedString(12),
  user LowCardinality(String),
  action LowCardinality(String),           -- exec/enter/stop/start/rm/cp/logs
  cmd Nullable(String),                    -- actual command for exec
  duration_seconds Nullable(UInt32),
  exit_code Nullable(UInt16),
  source_ip Nullable(String),
  success UInt8                            -- 1=success, 0=failure
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp);
```

### 3.6 Aggregate Tables

Materialized views for common query patterns.

```sql
-- Per-project daily resource usage
CREATE MATERIALIZED VIEW infra.container_stats_daily
ENGINE = AggregatingMergeTree()
ORDER BY (project, day)
AS SELECT
  project,
  toDate(timestamp) AS day,
  uniq(container_id) AS container_count,
  avg(cpu_percent) AS avg_cpu,
  max(cpu_percent) AS max_cpu,
  avg(memory_usage_bytes) AS avg_memory,
  max(memory_usage_bytes) AS max_memory,
  sum(network_rx_bytes + network_tx_bytes) AS total_network_bytes,
  sum(block_read_bytes + block_write_bytes) AS total_disk_io_bytes
FROM infra.container_stats
GROUP BY project, day;

-- Per-project hourly access count
CREATE MATERIALIZED VIEW infra.access_hourly
ENGINE = AggregatingMergeTree()
ORDER BY (project, hour)
AS SELECT
  project,
  toStartOfHour(timestamp) AS hour,
  uniq(user) AS active_users,
  count() AS action_count,
  countIf(success = 0) AS failure_count
FROM infra.access_log
GROUP BY project, hour;
```

---

## 4. Collection Pipeline

### 4.1 Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Docker Host                        │
│                                                       │
 │  docker stats (15s interval)         │
 │  docker events (stream)             │
 │  docker system df (5min interval)   │
 │  docker inspect (1h / on-demand)    │
 │  kyb exec logs (stream via syslog)  │
 │        │                             │
 │        ▼                             │
 │  ┌──────────┐                       │
 │  │  Vector   │──── ClickHouse ──── Grafana │
 │  └──────────┘                       │
 └─────────────────────────────────────────────────────┘
```

### 4.2 Vector Configuration

```toml
# /etc/vector/vector.toml (per-cluster)

[sources.docker_stats]
type = "exec"
command = ["docker", "stats", "--no-stream", "--format", "json"]
interval_secs = 15
mode = "streaming"

[sources.docker_events]
type = "exec"
command = ["docker", "events", "--format", "json"]
mode = "streaming"

[sources.docker_df]
type = "exec"
command = ["docker", "system", "df", "--verbose", "--format", "json"]
interval_secs = 300
mode = "scheduled"

[sources.kyb_syslog]
type = "syslog"
address = "0.0.0.0:514"
mode = "tcp"

[transforms.enrich_tenancy]
type = "remap"
inputs = ["docker_stats", "docker_events", "docker_df"]
source = '''
  # Extract kyb labels from container metadata
  project = del(.labels."kyb.project") ?? "unknown"
  sandbox = del(.labels."kyb.sandbox") ?? "unknown"
  cluster = del(.labels."kyb.cluster") ?? "unknown"
  user = del(.labels."kyb.user") ?? "unknown"
  .project = project
  .sandbox = sandbox
  .cluster = cluster
  .user = user
'''

[sinks.clickhouse_container_stats]
type = "clickhouse"
inputs = ["enrich_tenancy"]
endpoint = "http://clickhouse:8123"
table = "infra.container_stats"
encoding = "json"

[sinks.clickhouse_container_events]
type = "clickhouse"
inputs = ["enrich_tenancy"]
endpoint = "http://clickhouse:8123"
table = "infra.container_events"
encoding = "json"

[sinks.clickhouse_access_log]
type = "clickhouse"
inputs = ["kyb_syslog"]
endpoint = "http://clickhouse:8123"
table = "infra.access_log"
encoding = "json"
```

### 4.3 CLI Integration

`kyb` itself must emit structured access logs. Add a `--log-json` flag or syslog output:

```ruby
# lib/kyb/audit.rb (new)
module Kyb
  module Audit
    def self.log(action:, sandbox:, container_id:, user: nil, cmd: nil, duration: nil, exit_code: nil, success: true)
      entry = {
        timestamp: Time.now.utc.iso8601(3),
        cluster:   Kyb.config.cluster,
        project:   Kyb.config.project,
        sandbox:   sandbox,
        container_id: container_id,
        user:      user || ENV["USER"],
        action:    action,
        cmd:       cmd,
        duration_seconds: duration,
        exit_code: exit_code,
        success:   success ? 1 : 0
      }
      # Write to syslog or JSON file for Vector pickup
      Syslog.open("kyb", Syslog::LOG_PID | Syslog::LOG_CONS) do |s|
        s.info entry.to_json
      end
    rescue StandardError => e
      # Silent fail — audit should never block the primary operation
      warn "audit log failed: #{e.message}"
    end
  end
end
```

---

## 5. Alert Rules

### 5.1 Resource Hog — Single Container

```yaml
# /etc/vector/alerting/rules/resource_hog.yml
groups:
  - name: multi_tenancy
    rules:
      - alert: ContainerResourceHog
        expr: |
          avg_over_time(infra_container_stats_cpu_percent{project!="system"}[5m]) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Container {{ $labels.sandbox }} ({{ $labels.project }}) CPU > 80% for 5min"
```

### 5.2 Memory Near Limit

```yaml
      - alert: ContainerMemoryPressure
        expr: |
          infra_container_stats_memory_percent{project!="system"} > 85
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Container {{ $labels.sandbox }} memory at {{ $value }}% of limit"
```

### 5.3 Cross-Project Network Communication

```yaml
      - alert: CrossProjectNetworkAccess
        expr: |
          count by (container_id, project)
            infra_container_network_peers{project != infra_container_network_peers_project} > 0
        labels:
          severity: critical
        annotations:
          summary: "Container {{ $labels.container_id }} ({{ $labels.project }}) can reach containers of another project"
```

### 5.4 Unexpected Privileged Mode

```yaml
      - alert: PrivilegedContainerDetected
        expr: |
          infra_container_inspect_privileged{project!="system"} == 1
        labels:
          severity: critical
        annotations:
          summary: "Container {{ $labels.sandbox }} ({{ $labels.project }}) is running in privileged mode"
```

### 5.5 Shared Docker Socket

```yaml
      - alert: SharedDockerSocket
        expr: |
          infra_container_mounts{mount_destination="/var/run/docker.sock", project!="kyb"}
        labels:
          severity: high
        annotations:
          summary: "Container {{ $labels.sandbox }} ({{ $labels.project }}) has Docker socket mounted"
```

### 5.6 Host Volume Boundary Violation

```yaml
      - alert: HostMountOutsideProjectDir
        expr: |
          infra_container_mounts{mount_source!~"/home/.*"}
        labels:
          severity: high
        annotations:
          summary: "Container {{ $labels.sandbox }} mounts host path outside home: {{ $labels.mount_source }}"
```

### 5.7 No Project Label

```yaml
      - alert: UntaggedContainer
        expr: |
          infra_container_stats{project="unknown"} > 0
        labels:
          severity: warning
        annotations:
          summary: "Container {{ $labels.container_id }} has no kyb.project label"
```

### 5.8 Orphan Container (Stopped > 7 Days)

```yaml
      - alert: OrphanContainer
        expr: |
          time() - infra_container_events{event_type="stop"} > 604800
        labels:
          severity: info
        annotations:
          summary: "Container {{ $labels.sandbox }} ({{ $labels.project }}) stopped for >7 days"
```

---

## 6. Grafana Dashboards

### 6.1 Tenant Resource Dashboard

**Panel: Per-Project CPU/Memory (Bar Chart)**
- X-axis: project
- Y-axis: avg CPU % and avg memory %
- Color: one series per cluster
- Query:
  ```sql
  SELECT
    project,
    avg(cpu_percent) AS avg_cpu,
    avg(memory_percent) AS avg_mem
  FROM infra.container_stats
  WHERE timestamp > now() - INTERVAL 1 HOUR
  GROUP BY project
  ```

**Panel: Top-N Container by Resource (Table)**
- Columns: project, sandbox, cpu%, mem%, network, disk I/O
- Sortable by any column
- Threshold: red when CPU > 80 or memory > 85

**Panel: Container Count Per Project (Time Series)**
- X-axis: time
- Y-axis: container count
- Series: one line per project
- Query:
  ```sql
  SELECT
    toStartOfMinute(timestamp) AS t,
    project,
    uniq(container_id) AS cnt
  FROM infra.container_stats
  WHERE timestamp > now() - INTERVAL 24 HOUR
  GROUP BY t, project
  ```

### 6.2 Isolation Health Dashboard

**Panel: Isolation Violations (Table)**
- Show only containers with cross-project network, privileged mode, or host mount violations
- Columns: sandbox, project, violation_type, detail
- Color: red for critical, yellow for high

**Panel: Network Boundary Map (Node Graph)**
- Nodes: containers, colored by project
- Edges: network reachability
- Only render if cross-project edges exist

**Panel: Untagged Containers Counter (Singlestat)**
- Count of containers with `project=unknown`
- Red if > 0

### 6.3 Access Audit Dashboard

**Panel: User Activity by Project (Heatmap)**
- X-axis: hour of day
- Y-axis: project
- Color: action count
- Query:
  ```sql
  SELECT
    project,
    toHour(timestamp) AS hour,
    count() AS cnt
  FROM infra.access_log
  WHERE timestamp > now() - INTERVAL 7 DAY
  GROUP BY project, hour
  ```

**Panel: Recent Exec Commands (Logs Table)**
- Columns: time, user, sandbox, command
- Filterable by project, user
- Limit: last 200 entries

**Panel: Failed Actions by User (Bar Chart)**
- X-axis: user
- Y-axis: failed action count
- Series: one per action type

### 6.4 Capacity Planning Dashboard

**Panel: Disk Usage by Project (Pie Chart)**
- Slices: per-project total container disk
- Query:
  ```sql
  SELECT
    project,
    sum(container_disk_bytes) AS total_disk
  FROM infra.container_stats
  WHERE timestamp > now() - INTERVAL 10 MINUTE
  GROUP BY project
  ```

**Panel: Project Growth Trend (Area Chart)**
- X-axis: day
- Y-axis: container count
- Stacked area: cumulative container-days per project

**Panel: Resource Distribution (Histogram)**
- CPU percent buckets: 0-10, 10-20, ..., 90-100
- One series per project
- Shows how evenly (or unevenly) resources are consumed

---

## 7. Patrol Integration

The 5-minute patrol cycle (see `5min-patrol-guide.md`) should include multi-tenancy checks:

```bash
# ~/.kyb/patrol/multi-tenancy.sh

# 1. Check for untagged containers
UNTAGGED=$(docker ps --filter "label=kyb.project" --format "{{.ID}}" | wc -l)
TOTAL=$(docker ps --format "{{.ID}}" | wc -l)
if [ "$UNTAGGED" -lt "$TOTAL" ]; then
  echo "WARN: $((TOTAL - UNTAGGED)) containers missing kyb.project label"
fi

# 2. Check for privileged containers
PRIVILEGED=$(docker ps --filter "status=running" --format "{{.ID}}" | \
  xargs -I{} docker inspect {} --format '{{.HostConfig.Privileged}}' | \
  grep -c true)
if [ "$PRIVILEGED" -gt 0 ]; then
  echo "WARN: $PRIVILEGED privileged containers running"
fi

# 3. Check cross-network connectivity (requires network audit table)
# (New) Query ClickHouse for cross-project network edges

# 4. Report per-project container count
docker ps --format '{{.ID}} {{.Label "kyb.project"}}' | \
  awk '{count[$2]++} END {for (p in count) print "project=" p " containers=" count[p]}'
```

Patrol result fields added to heartbeat:
```json
{
  "patrol_multi_tenancy": {
    "untagged_containers": 0,
    "privileged_containers": 0,
    "cross_project_network": false,
    "projects": {
      "kyb": 3,
      "cc-connect": 2,
      "system": 5
    }
  }
}
```

---

## 8. Implementation Plan

### Phase 1 — Foundation (Do Now)

| Step | Description | Owner |
|------|-------------|-------|
| 1.1 | Add kyb.project/kyb.sandbox/kyb.cluster/kyb.user labels to all `kyb create` and `kyb did create` invocations | CLI |
| 1.2 | Add `lib/kyb/audit.rb` for structured access logging | CLI |
| 1.3 | Set up Vector sources for docker stats, events, system df on mac-orbstack | Infra |
| 1.4 | Deploy ClickHouse tables `infra.container_stats`, `infra.container_events`, `infra.access_log` | Infra |

### Phase 2 — Observability (This Week)

| Step | Description | Owner |
|------|-------------|-------|
| 2.1 | Configure Vector transforms for tenancy enrichment | Infra |
| 2.2 | Deploy Grafana dashboards: Tenant Resource, Access Audit | Infra |
| 2.3 | Deploy alerts: resource hog, untagged container, privileged mode | Infra |
| 2.4 | Add patrol checks for multi-tenancy | Infra |

### Phase 3 — Deep Isolation (Next Week)

| Step | Description | Owner |
|------|-------------|-------|
| 3.1 | Add `infra.container_network` table and periodic `docker inspect` collection | Infra |
| 3.2 | Add `infra.container_mounts` table for volume boundary tracking | Infra |
| 3.3 | Deploy cross-project network detection alert | Infra |
| 3.4 | Deploy host mount boundary violation alert | Infra |
| 3.5 | Backfill aggregate tables and materialized views | Infra |

### Phase 4 — Hardening (Future)

| Step | Description | Owner |
|------|-------------|-------|
| 4.1 | Enforce resource limits per project via Docker Compose or kyb config | CLI/Infra |
| 4.2 | Add per-project network namespaces (docker network per project) | CLI |
| 4.3 | Implement resource quota enforcer agent (auto-stop hog containers) | Infra |
| 4.4 | Retention policy: raw stats 30d, aggregated 1yr | Infra |
| 4.5 | Multi-cluster aggregation: super-boss queries all cluster CK instances | Super-boss |

---

## 9. Appendix: Key Metrics

### Per-Project Resource Score

A composite score for fair-share monitoring:

```
resource_score = normalized(cpu) * 0.3
               + normalized(memory) * 0.3
               + normalized(disk) * 0.2
               + normalized(network) * 0.2

normalized(x) = x / (total_cluster_resource / project_count)
```

Score > 2.0 = potential noise neighbor. Score < 0.2 = underutilized allocation.

### Audit Retention

| Data Type | Retention | Storage Est. (100 containers) |
|-----------|-----------|-------------------------------|
| Container stats (15s interval) | 30 days | ~2 GB |
| Container events | 90 days | ~100 MB |
| Access logs | 1 year | ~500 MB |
| Network snapshots (1h) | 30 days | ~50 MB |
| Mount snapshots (1h) | 30 days | ~30 MB |
| Aggregates | 1 year | ~200 MB |
| **Total** | | **~2.9 GB** |

### Related Documents

| Document | Relation |
|----------|----------|
| `multi-cluster-boss-architecture.md` | Cluster topology for multi-tenancy |
| `5min-patrol-guide.md` | Patrol integration for isolation checks |
| `user-activity.md` | User heatmap — access audit feeds into this |
| `session-monitor.md` | Session-level isolation (cc-connect sessions per project) |
| `crash-loop.md` | Resource hog detection overlaps |
| `disk-growth.md` | Per-project disk tracking |
| `observability-design.md` | Overall observability architecture |
