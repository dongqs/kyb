---
decision: 现在就做
---

# ClickHouse Schema — Consolidated Migration Script

> **Source**: All `docs/infra/reviews/*.md` files. Each ``CREATE`` statement is annotated with its source file.
> **Target**: Central ClickHouse instance (`host.orb.internal:8123`).
> **Usage**: `clickhouse-client --host host.orb.internal --multiquery < ck-schema-ready.md`
> **Status**: Standby — run once before deploying any review pipeline.

---

## Table of Contents

1. [Database `infra`](#database-infra)
2. [Database `cc`](#database-cc)
3. [Database `patrol`](#database-patrol)
4. [Database `boss`](#database-boss)
5. [Database `mcp`](#database-mcp)
6. [Database `net`](#database-net)
7. [Database `monitor`](#database-monitor)
8. [Database `otel`](#database-otel)
9. [Database `kyb`](#database-kyb)
10. [Database `feishu`](#database-feishu)
11. [No-Database Tables](#no-database-tables)

---

## Database `infra`

```sql
CREATE DATABASE IF NOT EXISTS infra;
```

### `infra.incident_response_log`
**Source**: `incident-slo.md` (Appendix A, definitive version)

```sql
CREATE TABLE IF NOT EXISTS infra.incident_response_log (
    incident_id      String,
    alert_name       String,
    severity         Enum8('P0'=0, 'P1'=1, 'P2'=2, 'P3'=3),
    service          String,
    cluster          String DEFAULT 'mac-orbstack',
    fire_time        DateTime64(3),
    ack_time         Nullable(DateTime64(3)),
    resolve_time     DateTime64(3),
    tta_seconds      Nullable(UInt32),
    ttr_seconds      Nullable(UInt32),
    acked            UInt8 DEFAULT 0,
    slo_met          UInt8 DEFAULT 0,
    summary          String DEFAULT '',
    runbook          String DEFAULT '',
    insert_time      DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(fire_time)
ORDER BY (severity, fire_time, incident_id)
TTL fire_time + INTERVAL 1 YEAR DELETE;
```

### `infra.incident_slo_daily_mv` (Materialized View)
**Source**: `incident-slo.md` (Appendix A)

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS infra.incident_slo_daily_mv
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (severity, date)
POPULATE
AS SELECT
    severity,
    toDate(fire_time) AS date,
    count(*) AS total_incidents,
    sum(slo_met) AS compliant_incidents,
    avg(tta_seconds) AS avg_tta,
    avg(ttr_seconds) AS avg_ttr,
    quantileState(0.50)(tta_seconds) AS tta_p50_state,
    quantileState(0.95)(tta_seconds) AS tta_p95_state,
    quantileState(0.99)(tta_seconds) AS tta_p99_state,
    quantileState(0.50)(ttr_seconds) AS ttr_p50_state,
    quantileState(0.95)(ttr_seconds) AS ttr_p95_state,
    quantileState(0.99)(ttr_seconds) AS ttr_p99_state,
    sum(if(acked=0, 1, 0)) AS auto_resolved_count
FROM infra.incident_response_log
GROUP BY severity, toDate(fire_time);
```

### `infra.image_pulls`
**Source**: `image-pull.md`

```sql
CREATE TABLE infra.image_pulls (
    event_time          DateTime                COMMENT 'Pull completion time',
    image               LowCardinality(String)  COMMENT 'Image name without tag',
    tag                 LowCardinality(String)  COMMENT 'Image tag',
    registry            LowCardinality(String)  COMMENT 'Registry host',
    pull_duration_ms    UInt32                  COMMENT 'Total pull time in milliseconds',
    layers_total        UInt16                  COMMENT 'Total layers in the image',
    layers_cached       UInt16                  COMMENT 'Layers served from local cache',
    layers_pulled       UInt16                  COMMENT 'Layers downloaded fresh',
    bytes_transferred   UInt64                  COMMENT 'Total bytes downloaded',
    cache_status        LowCardinality(String)  COMMENT 'up_to_date | fresh_pull | partial_cache | unknown',
    exit_code           UInt8                   COMMENT '0 = success, non-zero = failure',
    boss_id             LowCardinality(String)  COMMENT 'Hostname of the boss container',
    cluster             LowCardinality(String)  COMMENT 'Cluster identifier',
    error_message       String DEFAULT ''       COMMENT 'Error message if pull failed',
    cache_hit_ratio     Float32                 COMMENT 'layers_cached / layers_total',
    pull_speed_bps      Float64                 COMMENT 'bytes_transferred / duration in bytes/sec',
    image_full          String DEFAULT ''       COMMENT 'image:tag for convenience',
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (event_time, registry, image)
TTL event_time + INTERVAL 90 DAY;
```

### `infra.image_pull_layers`
**Source**: `image-pull.md`

```sql
CREATE TABLE infra.image_pull_layers (
    event_time      DateTime                COMMENT 'Pull completion time',
    image           LowCardinality(String)  COMMENT 'Image name',
    tag             LowCardinality(String)  COMMENT 'Image tag',
    layer_digest    String                  COMMENT 'Layer sha256 digest',
    layer_index     UInt16                  COMMENT 'Layer position (0 = bottom)',
    layer_size      UInt64                  COMMENT 'Layer size in bytes',
    was_cached      UInt8                   COMMENT '1 = cache hit, 0 = cache miss',
    pull_duration_ms UInt32                 COMMENT 'Time to pull this layer',
    boss_id         LowCardinality(String)
) ENGINE = MergeTree
ORDER BY (event_time, image)
TTL event_time + INTERVAL 30 DAY;
```

### `infra.registry_requests`
**Source**: `image-pull.md`

```sql
CREATE TABLE infra.registry_requests (
    event_time      DateTime                COMMENT 'Request timestamp',
    remote_addr     String                  COMMENT 'Client IP',
    method          LowCardinality(String)  COMMENT 'HTTP method',
    path            String                  COMMENT 'Request path',
    status          UInt16                  COMMENT 'HTTP status',
    bytes_sent      UInt64                  COMMENT 'Response body bytes',
    request_time_sec Float32                COMMENT 'Request processing time',
    image_path      String                  COMMENT 'Extracted image path from URL',
    request_type    LowCardinality(String)  COMMENT 'blob | manifest | catalog | other',
    blob_digest     String DEFAULT ''       COMMENT 'Blob digest',
    tag_or_digest   String DEFAULT ''       COMMENT 'Tag or digest for manifests',
    cache_hit       UInt8                   COMMENT '1 = blob served from cache',
    boss_id         LowCardinality(String)  COMMENT 'Boss hostname',
    cluster         LowCardinality(String)  COMMENT 'Cluster identifier',
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (event_time, image_path, status)
TTL event_time + INTERVAL 14 DAY;
```

### `infra.config_baselines`
**Source**: `config-drift.md`

```sql
CREATE TABLE infra.config_baselines (
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),
    snapshot_id     String,
    check_time      DateTime64(3),
    file_path       String,
    checksum_sha256 String,
    file_size       UInt32,
    file_mode       String,
    git_status      LowCardinality(String),
    _ingested_at    DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_ingested_at)
ORDER BY (boss_id, file_path, check_time);
```

### `infra.config_drifts`
**Source**: `config-drift.md`

```sql
CREATE TABLE infra.config_drifts (
    boss_id            LowCardinality(String),
    cluster            LowCardinality(String),
    detect_time        DateTime64(3),
    file_path          String,
    baseline_checksum  String,
    current_checksum   String,
    file_size          UInt32,
    file_mode          String,
    git_status         LowCardinality(String),
    suspect            String,
    diff_preview       String DEFAULT '',
    resolved_at        Nullable(DateTime64(3)),
    resolution         LowCardinality(String) DEFAULT '',
    resolution_note    String DEFAULT '',
    drift_duration_seconds Nullable(Int32),
    _ingested_at       DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (detect_time, boss_id, file_path)
TTL detect_time + INTERVAL 365 DAY;
```

### `infra.config_snapshots`
**Source**: `config-drift.md`

```sql
CREATE TABLE infra.config_snapshots (
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),
    snapshot_id     String,
    snapshot_time   DateTime64(3),
    file_count      UInt8,
    snapshot_json   String,
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (snapshot_time, boss_id)
TTL snapshot_time + INTERVAL 365 DAY;
```

### `infra.patrol_log`
**Source**: `boss-decision-latency.md`

```sql
CREATE TABLE IF NOT EXISTS infra.patrol_log (
    boss_id            LowCardinality(String),
    cluster            LowCardinality(String),
    patrol_time        DateTime64(3),
    patrol_status      LowCardinality(String),
    anomalies_found    UInt8 DEFAULT 0,
    docker_running     UInt16,
    docker_total       UInt16,
    disk_used_pct      UInt8,
    mem_used_pct       UInt8,
    load_1m            Float32,
    patrol_1_age_sec   UInt16,
    patrol_2_age_sec   UInt16,
    patrol_3_age_sec   UInt16,
    anomalies          String DEFAULT '[]',
    _ingested_at       DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (patrol_time, cluster, boss_id)
TTL patrol_time + INTERVAL 90 DAY;
```

### `infra.decision_log`
**Source**: `boss-decision-latency.md`

```sql
CREATE TABLE IF NOT EXISTS infra.decision_log (
    boss_id            LowCardinality(String),
    cluster            LowCardinality(String),
    decision_time      DateTime64(3),
    trigger_type       LowCardinality(String),
    decision_type      LowCardinality(String),
    trigger_time       DateTime64(3),
    latency_sec        UInt32,
    reference_type     LowCardinality(String),
    reference_id       String,
    subagent_session_id String DEFAULT '',
    parent_session_id   String DEFAULT '',
    notes              String DEFAULT '',
    _ingested_at       DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (decision_time, trigger_type, decision_type)
TTL decision_time + INTERVAL 90 DAY;
```

### `infra.issue_latency`
**Source**: `boss-decision-latency.md`

```sql
CREATE TABLE IF NOT EXISTS infra.issue_latency (
    issue_iid           UInt32,
    project             String,
    cluster             LowCardinality(String),
    issue_created_at    DateTime64(3),
    first_action_at     DateTime64(3),
    first_action_type   LowCardinality(String),
    ial_sec             UInt32,
    assignee            String DEFAULT '',
    title               String DEFAULT '',
    severity            LowCardinality(String) DEFAULT 'normal',
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (issue_created_at, cluster)
TTL issue_created_at + INTERVAL 90 DAY;
```

### `infra.e2e_cycle_times`
**Source**: `boss-decision-latency.md`

```sql
CREATE TABLE IF NOT EXISTS infra.e2e_cycle_times (
    cycle_id         UUID DEFAULT generateUUIDv4(),
    trigger_type     LowCardinality(String),
    trigger_time     DateTime64(3),
    cluster          LowCardinality(String),
    description      String,
    patrol_time      DateTime64(3),
    dispatch_time    DateTime64(3),
    subagent_start   DateTime64(3),
    subagent_stop    DateTime64(3),
    decision_time    DateTime64(3),
    mr_created_time  DateTime64(3),
    mr_merged_time   DateTime64(3),
    master_ci_time   DateTime64(3),
    pdl_sec          Nullable(UInt32),
    stt_sec          Nullable(UInt32),
    bdt_sec          Nullable(UInt32),
    mrl_sec          Nullable(UInt32),
    cil_sec          Nullable(UInt32),
    e2e_sec          UInt32,
    _ingested_at     DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (cycle_id, trigger_time)
TTL trigger_time + INTERVAL 90 DAY;
```

### `infra.docker_events`
**Source**: `docker-events.md`

```sql
CREATE TABLE infra.docker_events (
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),
    event_time      DateTime64(3),
    event_type      LowCardinality(String),
    container_name  String,
    actor_id        String,
    image           String,
    exit_code       UInt8 DEFAULT 0,
    health_status   String DEFAULT '',
    oom_killed      UInt8 DEFAULT 0,
    restart_count   UInt16 DEFAULT 0,
    raw_json        String DEFAULT '',
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (event_time, boss_id, event_type)
TTL event_time + INTERVAL 90 DAY;
```

### `infra.alerts`
**Source**: `alert-fatigue.md`

```sql
CREATE TABLE infra.alerts (
    timestamp          DateTime64(3)       CODEC(ZSTD(3)),
    alert_id           String,
    alertname          LowCardinality(String),
    severity           LowCardinality(String),
    source             LowCardinality(String),
    team               LowCardinality(String),
    labels             Map(String, String),
    annotations        Map(String, String),
    fingerprint        String,
    fired_at           DateTime64(3),
    acknowledged_at    Nullable(DateTime64(3)),
    silenced_at        Nullable(DateTime64(3)),
    resolved_at        Nullable(DateTime64(3)),
    action_required    Nullable(Bool),
    action_taken       Nullable(String),
    false_reason       Nullable(String),
    silence_reason     Nullable(String),
    mtta_seconds       Nullable(Int32),
    duration_seconds   Nullable(Int32)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, alertname, severity)
TTL timestamp + INTERVAL 365 DAY DELETE;
```

### `infra.alerts_daily_mv` (Materialized View)
**Source**: `alert-fatigue.md`

```sql
CREATE MATERIALIZED VIEW infra.alerts_daily_mv
ENGINE = AggregatingMergeTree
ORDER BY (date, alertname)
AS SELECT
    toDate(timestamp) AS date,
    alertname,
    severity,
    team,
    source,
    count() AS total_alerts,
    countIf(acknowledged_at IS NOT NULL) AS acknowledged,
    countIf(resolved_at IS NOT NULL) AS resolved,
    countIf(acknowledged_at IS NULL AND resolved_at IS NOT NULL) AS auto_resolved,
    avg(mtta_seconds) AS avg_mtta,
    avg(duration_seconds) AS avg_duration
FROM infra.alerts
GROUP BY date, alertname, severity, team, source;
```

### `infra.incident_log`
**Source**: `incident-severity.md`

```sql
CREATE TABLE infra.incident_log (
    event_time     DateTime64(3)   DEFAULT now64(),
    incident_id    String,
    severity       Enum8('P0'=0, 'P1'=1, 'P2'=2, 'P3'=3, 'P4'=4),
    service        LowCardinality(String),
    cluster        LowCardinality(String),
    cause          LowCardinality(String),
    detection      LowCardinality(String),
    title          String,
    declared_at    DateTime64(3),
    resolved_at    DateTime64(3),
    duration_sec   Int32,
    acknowledged_at DateTime64(3),
    mtta_sec       Int32,
    resolved_by    String,
    tag_changes    Array(Tuple(DateTime64(3), String, String)),
    notes          String
)
ENGINE = ReplacingMergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, incident_id);
```

### `infra.boss_lifecycle_events`
**Source**: `boss-lifecycle.md`

```sql
CREATE TABLE infra.boss_lifecycle_events (
    event_id        UUID DEFAULT generateUUIDv4(),
    boss_id         String,
    cluster         LowCardinality(String),
    event_type      Enum8(
        'created'     = 1,
        'started'     = 2,
        'stopped'     = 3,
        'destroyed'   = 4,
        'crashed'     = 5,
        'restarted'   = 6,
        'heartbeat_lost' = 7,
        'cleanup'     = 8
    ),
    timestamp       DateTime64(3) DEFAULT now64(),
    boss_version    String,
    host_machine    String,
    container_id    String,
    host_uptime     UInt32,
    session_id      UInt64,
    payload         String
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), cluster, boss_id, event_type)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `infra.boss_current` (Materialized View)
**Source**: `boss-lifecycle.md`

```sql
CREATE MATERIALIZED VIEW infra.boss_current
ENGINE = ReplacingMergeTree(timestamp)
ORDER BY (boss_id)
POPULATE AS
SELECT argMax(boss_id, timestamp) AS boss_id,
       argMax(cluster, timestamp),
       argMax(event_type, timestamp) AS current_state,
       argMax(timestamp, timestamp) AS last_event_at,
       argMax(boss_version, timestamp),
       argMax(host_machine, timestamp),
       argMax(container_id, timestamp),
       argMax(session_id, timestamp)
FROM infra.boss_lifecycle_events
GROUP BY boss_id;
```

### `infra.boss_sessions`
**Source**: `boss-lifecycle.md`

```sql
CREATE TABLE infra.boss_sessions (
    boss_id              String,
    cluster              LowCardinality(String),
    incarnation_id       UInt64,
    version              String,
    host_machine         String,
    container_id         String,
    started_at           DateTime64(3),
    ended_at             DateTime64(3),
    duration_seconds     UInt32,
    end_reason           LowCardinality(String),
    sandbox_count_peak   UInt16,
    sandbox_count_total  UInt32
) ENGINE = ReplacingMergeTree(started_at)
ORDER BY (boss_id, incarnation_id)
TTL toDate(started_at) + INTERVAL 180 DAY;
```

### `infra.boss_sandbox_events`
**Source**: `boss-lifecycle.md`

```sql
CREATE TABLE infra.boss_sandbox_events (
    event_id        UUID DEFAULT generateUUIDv4(),
    boss_id         String,
    cluster         LowCardinality(String),
    timestamp       DateTime64(3) DEFAULT now64(),
    action          Enum8('create' = 1, 'destroy' = 2, 'exec' = 3),
    sandbox_name    String,
    sandbox_id      String,
    duration_ms     UInt32 DEFAULT 0,
    exit_code       UInt8 DEFAULT 0
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), boss_id, action)
TTL toDate(timestamp) + INTERVAL 30 DAY;
```

### `infra.lessons_learned`
**Source**: `postmortem.md`

```sql
CREATE TABLE infra.lessons_learned (
    id              UUID DEFAULT generateUUIDv4(),
    created_at      DateTime DEFAULT now(),
    incident_date   Date,
    incident_id     String,
    postmortem_path String,
    severity        LowCardinality(String),
    service         LowCardinality(String),
    cluster         LowCardinality(String),
    failure_class   LowCardinality(String),
    lesson          String,
    context         String,
    tags            Array(String),
    has_action_item Bool DEFAULT true,
    action_item_ids Array(String),
    action_item_status String DEFAULT 'open',
    author          LowCardinality(String),
    reviewer        LowCardinality(String)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(incident_date)
ORDER BY (incident_date, service, failure_class)
TTL incident_date + INTERVAL 3 YEAR DELETE;
```

### `infra.post_mortems`
**Source**: `postmortem.md`

```sql
CREATE TABLE infra.post_mortems (
    id                    UUID DEFAULT generateUUIDv4(),
    created_at            DateTime DEFAULT now(),
    updated_at            DateTime DEFAULT now(),
    incident_date         Date,
    incident_id           String,
    file_path             String,
    title                 String,
    severity              LowCardinality(String),
    status                LowCardinality(String),
    author                LowCardinality(String),
    reviewer              LowCardinality(String),
    duration_minutes      UInt32,
    users_affected        Nullable(UInt32),
    error_budget_consumed Nullable(Float32),
    data_loss             Bool DEFAULT false,
    mtta_minutes          Nullable(UInt32),
    mttr_minutes          Nullable(UInt32),
    direct_cause          String,
    failure_class         LowCardinality(String),
    action_item_count     UInt32 DEFAULT 0,
    action_item_closed    UInt32 DEFAULT 0,
    draft_deadline        Date,
    review_deadline       Date,
    draft_completed_at    Nullable(DateTime),
    review_completed_at   Nullable(DateTime),
    closed_at             Nullable(DateTime)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(incident_date)
ORDER BY (incident_date, severity, status)
TTL incident_date + INTERVAL 3 YEAR DELETE;
```

### `infra.action_items`
**Source**: `postmortem.md`

```sql
CREATE TABLE infra.action_items (
    id              UUID DEFAULT generateUUIDv4(),
    created_at      DateTime DEFAULT now(),
    updated_at      DateTime DEFAULT now(),
    incident_id     String,
    postmortem_path String,
    ai_id           String,
    description     String,
    type            LowCardinality(String),
    priority        LowCardinality(String),
    owner           LowCardinality(String),
    linked_issue    String,
    deadline        Date,
    status          LowCardinality(String),
    verified_at     Nullable(DateTime),
    verified_by     Nullable(String),
    closed_at       Nullable(DateTime)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(deadline)
ORDER BY (deadline, priority, status)
TTL deadline + INTERVAL 2 YEAR DELETE;
```

### `infra.mirror_probe_history`
**Source**: `registry-latency.md`

```sql
CREATE TABLE infra.mirror_probe_history (
    event_time      DateTime64(3)        COMMENT 'Probe timestamp',
    probe_source    LowCardinality(String) COMMENT 'Hostname of probing node',
    mirror          LowCardinality(String) COMMENT 'Mirror hostname',
    http_status     UInt16               COMMENT 'HTTP response status code',
    latency_ms      Nullable(UInt32)     COMMENT 'Total request latency',
    dns_ms          Nullable(UInt16)     COMMENT 'DNS lookup time',
    connect_ms      Nullable(UInt16)     COMMENT 'TCP connect time',
    tls_ms          Nullable(UInt16)     COMMENT 'TLS handshake time',
    error_type      LowCardinality(String) COMMENT 'Classified error type'
) ENGINE = MergeTree
ORDER BY (event_time, mirror, probe_source)
TTL event_time + INTERVAL 90 DAY;
```

### `infra.mirror_status_latest` (Materialized View)
**Source**: `registry-latency.md`

```sql
CREATE MATERIALIZED VIEW infra.mirror_status_latest
ENGINE = ReplacingMergeTree(event_time)
ORDER BY (mirror, probe_source)
POPULATE AS
SELECT
    mirror,
    probe_source,
    argMax(event_time, event_time)          AS last_probe_time,
    argMax(http_status, event_time)         AS last_http_status,
    argMax(latency_ms, event_time)          AS last_latency_ms,
    argMax(error_type, event_time)          AS last_error_type,
    count(*)                                 AS probe_count_24h,
    countIf(error_type = 'ok')              AS ok_count_24h,
    countIf(error_type != 'ok')             AS fail_count_24h,
    max(latency_ms)                          AS max_latency_24h,
    avg(latency_ms)                          AS avg_latency_24h
FROM infra.mirror_probe_history
WHERE event_time > now() - INTERVAL 24 HOUR
GROUP BY mirror, probe_source;
```

### `infra.mirror_failover_events`
**Source**: `registry-latency.md`

```sql
CREATE TABLE infra.mirror_failover_events (
    event_time      DateTime64(3)        COMMENT 'Failover trigger time',
    probe_source    LowCardinality(String) COMMENT 'Node that performed failover',
    old_mirror      LowCardinality(String) COMMENT 'Previously active mirror',
    new_mirror      LowCardinality(String) COMMENT 'Mirror switched to',
    reason          String               COMMENT 'Trigger condition',
    daemon_json     String               COMMENT 'New daemon.json content (redacted)'
) ENGINE = MergeTree
ORDER BY (event_time, probe_source)
TTL event_time + INTERVAL 365 DAY;
```

### `infra.mcp_logs`
**Source**: `review-mcp-D3.md`

```sql
CREATE TABLE infra.mcp_logs (
    timestamp       DateTime64(3),
    level           LowCardinality(String),
    event           String,
    request_id      String,
    server          String,
    tool            String,
    params_size     UInt32,
    output_size     UInt32,
    latency_ms      UInt32,
    error_type      String,
    error_message   String,
    retry_count     UInt8,
    backoff_ms      UInt32,
    session_id      String,
    raw_json        String
) ENGINE = MergeTree()
ORDER BY (server, timestamp);
```

### `infra.build_cache_metrics`
**Source**: `cache-hit.md`

```sql
CREATE TABLE IF NOT EXISTS infra.build_cache_metrics (
    event_time              DateTime64(3) DEFAULT now64(),
    metric_type             LowCardinality(String),
    total_layers            UInt16 DEFAULT 0,
    cached_layers           UInt16 DEFAULT 0,
    rebuilt_layers          UInt16 DEFAULT 0,
    cache_hit_ratio         Float32 DEFAULT 0,
    build_duration          Float32 DEFAULT 0,
    proxy_used              UInt8 DEFAULT 0,
    dockerfile_hash         String DEFAULT '',
    build_host              LowCardinality(String) DEFAULT '',
    layer_index             UInt16 DEFAULT 0,
    layer_cached            UInt8 DEFAULT 0,
    layer_duration          Float32 DEFAULT 0,
    command_hash            String DEFAULT '',
    command_preview         String DEFAULT '',
    cache_total_bytes       Int64 DEFAULT 0,
    cache_reclaimable_bytes Int64 DEFAULT 0,
    cache_count             UInt32 DEFAULT 0,
    mount_path              String DEFAULT '',
    mount_bytes             Int64 DEFAULT 0,
    _ingested_at            DateTime DEFAULT now(),
    raw_payload             String CODEC(ZSTD(3)) DEFAULT ''
)
ENGINE = MergeTree
ORDER BY (toDate(event_time), metric_type, build_host)
TTL toDate(event_time) + INTERVAL 180 DAY
SETTINGS index_granularity = 8192;
```

### `infra.build_cache_hit_daily` (Materialized View)
**Source**: `cache-hit.md`

```sql
CREATE MATERIALIZED VIEW infra.build_cache_hit_daily
ENGINE = SummingMergeTree
ORDER BY (day, build_host)
AS SELECT
    toDate(event_time) AS day,
    build_host,
    count() AS build_count,
    sum(total_layers) AS total_layers,
    sum(cached_layers) AS cached_layers,
    avg(cache_hit_ratio) AS avg_hit_ratio,
    min(cache_hit_ratio) AS min_hit_ratio,
    max(cache_hit_ratio) AS max_hit_ratio
FROM infra.build_cache_metrics
WHERE metric_type = 'build_summary'
GROUP BY day, build_host;
```

### `infra.build_cache_layer_freq` (Materialized View)
**Source**: `cache-hit.md`

```sql
CREATE MATERIALIZED VIEW infra.build_cache_layer_freq
ENGINE = AggregatingMergeTree
ORDER BY (layer_index, command_hash)
AS SELECT
    layer_index,
    command_hash,
    anyLast(command_preview) AS command_preview,
    count() AS total_builds,
    sum(layer_cached) AS cache_hits,
    avg(layer_duration) AS avg_duration_rebuild
FROM infra.build_cache_metrics
WHERE metric_type = 'layer_detail'
GROUP BY layer_index, command_hash;
```

### `infra.ci_pipelines`
**Source**: `ci-flakiness.md`

```sql
CREATE TABLE infra.ci_pipelines (
    timestamp          DateTime64(3)       CODEC(ZSTD(3)),
    pipeline_id        UInt64,
    project            LowCardinality(String),
    ref                String,
    ref_type           LowCardinality(String),
    source             LowCardinality(String),
    status             LowCardinality(String),
    failure_reason     LowCardinality(String),
    failure_category   LowCardinality(String),
    duration_seconds   Float64,
    created_at         DateTime64(3),
    finished_at        Nullable(DateTime64(3)),
    git_sha            String,
    total_jobs         UInt8,
    failed_jobs        UInt8,
    mr_iid             Nullable(UInt32),
    mr_author          Nullable(String)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, project, status)
TTL timestamp + INTERVAL 365 DAY DELETE;
```

### `infra.ci_pass_rate_daily_mv` (Materialized View)
**Source**: `ci-flakiness.md`

```sql
CREATE MATERIALIZED VIEW infra.ci_pass_rate_daily_mv
ENGINE = AggregatingMergeTree
ORDER BY (date, project, ref_type)
AS SELECT
    toDate(timestamp) AS date,
    project,
    ref_type,
    source,
    count() AS total_pipelines,
    countIf(status = 'success') AS passed,
    countIf(status = 'failed') AS failed,
    countIf(status = 'canceled') AS canceled,
    countIf(failure_category = 'infrastructure') AS infra_failures,
    countIf(failure_category = 'script_failure') AS script_failures,
    countIf(status = 'success') / countIf(status IN ('success', 'failed') AND failure_category != 'infrastructure') AS code_pass_rate
FROM infra.ci_pipelines
GROUP BY date, project, ref_type, source;
```

### `infra.ci_jobs`
**Source**: `ci-flakiness.md`

```sql
CREATE TABLE infra.ci_jobs (
    timestamp          DateTime64(3)       CODEC(ZSTD(3)),
    pipeline_id        UInt64,
    job_id             UInt64,
    job_name           LowCardinality(String),
    stage              LowCardinality(String),
    status             LowCardinality(String),
    failure_reason     LowCardinality(String),
    failure_category   LowCardinality(String),
    runner             LowCardinality(String),
    duration_seconds   Float64,
    created_at         DateTime64(3),
    started_at         Nullable(DateTime64(3)),
    finished_at        Nullable(DateTime64(3)),
    ref                String,
    ref_type           LowCardinality(String),
    source             LowCardinality(String)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, pipeline_id, job_name);
```

### `infra.service_registry`
**Source**: `service-dependency.md`

```sql
CREATE TABLE infra.service_registry (
    service_id      LowCardinality(String),
    service_name    String,
    tier            UInt8,
    cluster         LowCardinality(String),
    service_type    LowCardinality(String),
    description     String,
    depends_on      Array(String),
    dep_types       Array(String),
    healthcheck_cmd String DEFAULT '',
    updated_at      DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY service_id;
```

### `infra.service_health`
**Source**: `service-dependency.md`

```sql
CREATE TABLE infra.service_health (
    event_time      DateTime64(3),
    service_id      LowCardinality(String),
    cluster         LowCardinality(String),
    status          LowCardinality(String),
    health_score    UInt8,
    signal_source   LowCardinality(String),
    latency_ms      Nullable(UInt32),
    error_message   String DEFAULT '',
    detail_json     String DEFAULT ''
) ENGINE = MergeTree
ORDER BY (toDate(event_time), service_id, cluster)
TTL event_time + INTERVAL 90 DAY;
```

### `infra.service_health_latest` (Materialized View)
**Source**: `service-dependency.md`

```sql
CREATE MATERIALIZED VIEW infra.service_health_latest
ENGINE = ReplacingMergeTree
ORDER BY (service_id, cluster)
POPULATE AS
SELECT
    argMax(event_time, event_time) AS last_updated,
    service_id,
    cluster,
    argMax(status, event_time) AS status,
    argMax(health_score, event_time) AS health_score,
    argMax(signal_source, event_time) AS signal_source,
    argMax(latency_ms, event_time) AS latency_ms,
    argMax(error_message, event_time) AS error_message
FROM infra.service_health
GROUP BY service_id, cluster;
```

### `infra.dependency_failures`
**Source**: `service-dependency.md`

```sql
CREATE TABLE infra.dependency_failures (
    event_time       DateTime64(3),
    failure_id       String,
    root_service     LowCardinality(String),
    affected_services Array(String),
    failure_type     LowCardinality(String),
    root_cause       String,
    duration_sec     UInt32,
    resolved_at      Nullable(DateTime64(3)),
    alert_suppressions Array(String)
) ENGINE = MergeTree
ORDER BY (toDate(event_time), root_service)
TTL event_time + INTERVAL 90 DAY;
```

### `infra.otel_spans` (unified-otel.md version)
**Source**: `unified-otel.md`

```sql
CREATE TABLE infra.otel_spans (
    timestamp           DateTime64(9),
    trace_id            String,
    span_id             String,
    parent_span_id      String,
    trace_state         String,
    span_name           String,
    span_kind           LowCardinality(String),
    service_name        LowCardinality(String),
    service_version     String,
    infra_cluster       LowCardinality(String),
    infra_hostname      String,
    infra_environment   LowCardinality(String),
    duration_ns         Int64,
    status_code         LowCardinality(String),
    status_message      String,
    span_attributes     JSON,
    resource_attributes JSON,
    events              JSON,
    links               JSON,
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service_name, infra_cluster, timestamp)
TTL timestamp + INTERVAL 90 DAY;
```

### `infra.otel_logs`
**Source**: `unified-otel.md`

```sql
CREATE TABLE infra.otel_logs (
    timestamp           DateTime64(9),
    observed_timestamp  DateTime64(9),
    severity_text       LowCardinality(String),
    severity_number     UInt8,
    body                String,
    service_name        LowCardinality(String),
    infra_cluster       LowCardinality(String),
    infra_hostname      String,
    attributes          JSON,
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service_name, infra_cluster, timestamp)
TTL timestamp + INTERVAL 90 DAY;
```

### `infra.fluentd_health`
**Source**: `fluentd-pipeline.md`

```sql
CREATE TABLE infra.fluentd_health (
    hostname String,
    cluster String,
    timestamp DateTime64(3),
    buffer_size_bytes UInt64,
    events_last_minute UInt32,
    errors_last_minute UInt32
) ENGINE = ReplacingMergeTree
ORDER BY (hostname, timestamp);
```

### `infra.message_log` (Unified Vector canonical)
**Source**: `unified-vector.md`

```sql
CREATE TABLE infra.message_log (
    schema_version  LowCardinality(String),
    source          LowCardinality(String),
    event_type      LowCardinality(String),
    event_time      DateTime64(3),
    cluster         LowCardinality(String),
    host            String,
    container_id    String,
    message         String,
    stream          LowCardinality(String),
    log_level       LowCardinality(String),
    log_source      String,
    msg_id          String DEFAULT '',
    session         String DEFAULT '',
    user            String DEFAULT '',
    content_len     UInt32 DEFAULT 0,
    has_images      UInt8 DEFAULT 0,
    tools           UInt8 DEFAULT 0,
    response_len    UInt32 DEFAULT 0,
    turn_duration   Float64 DEFAULT 0,
    input_tokens    UInt32 DEFAULT 0,
    output_tokens   UInt32 DEFAULT 0,
    outbound_tag    LowCardinality(String) DEFAULT ''
) ENGINE = MergeTree
ORDER BY (cluster, event_time, source)
TTL event_time + INTERVAL 90 DAY;
```

### `infra.token_usage`
**Source**: `token-cost.md`

```sql
CREATE TABLE infra.token_usage (
    session_id      LowCardinality(String),
    project         LowCardinality(String),
    agent_name      LowCardinality(String),
    timestamp       DateTime64(3),
    input_tokens    UInt32,
    output_tokens   UInt32,
    cache_read      UInt32 DEFAULT 0,
    cache_write     UInt32 DEFAULT 0,
    model           LowCardinality(String),
    provider        LowCardinality(String),
    estimated_cost  Float64 DEFAULT 0,
    currency        LowCardinality(String) DEFAULT 'USD',
    container_id    String DEFAULT '',
    boss_id         LowCardinality(String),
    cluster         LowCardinality(String),
    turn_number     UInt32 DEFAULT 0,
    duration_ms     UInt32 DEFAULT 0,
    error           UInt8 DEFAULT 0,
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (timestamp, project, session_id)
TTL timestamp + INTERVAL 365 DAY;
```

### `infra.token_usage_daily` (Materialized View)
**Source**: `token-cost.md`

```sql
CREATE MATERIALIZED VIEW infra.token_usage_daily
ENGINE = SummingMergeTree
ORDER BY (date, project, agent_name, model)
AS SELECT
    toDate(timestamp) AS date,
    project,
    agent_name,
    model,
    provider,
    sum(input_tokens) AS total_input_tokens,
    sum(output_tokens) AS total_output_tokens,
    sum(cache_read) AS total_cache_read,
    sum(cache_write) AS total_cache_write,
    sum(estimated_cost) AS total_cost,
    count() AS turns
FROM infra.token_usage
GROUP BY date, project, agent_name, model, provider;
```

### `infra.token_budgets`
**Source**: `token-cost.md`

```sql
CREATE TABLE infra.token_budgets (
    project         LowCardinality(String),
    budget_period   LowCardinality(String),
    budget_limit    Float64,
    alert_threshold Float64 DEFAULT 0.8,
    notify_channel  String DEFAULT 'feishu',
    enabled         UInt8 DEFAULT 1,
    _updated_at     DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (project, budget_period);
```

### `infra.model_pricing`
**Source**: `token-cost.md`

```sql
CREATE TABLE infra.model_pricing (
    model            LowCardinality(String),
    provider         LowCardinality(String),
    input_price      Float64,
    output_price     Float64,
    cache_read_price  Float64 DEFAULT 0,
    cache_write_price Float64 DEFAULT 0,
    effective_from   Date,
    effective_to     Date DEFAULT '9999-12-31'
) ENGINE = ReplacingMergeTree(effective_to)
ORDER BY (model, effective_from);
```

### `infra.tool_cost_profile`
**Source**: `token-efficiency.md`

```sql
CREATE TABLE infra.tool_cost_profile (
    computed_at         DateTime64(3),
    tool_name           LowCardinality(String),
    model               LowCardinality(String),
    invocations         UInt32,
    sessions            UInt32,
    avg_input_bytes     UInt32,
    avg_result_bytes    UInt32,
    est_input_tokens    UInt32,
    est_output_tokens   UInt32,
    est_cost_per_call   Float64,
    avg_duration_ms     UInt32,
    p95_duration_ms     UInt32,
    efficiency_score    UInt8,
    _ingested_at        DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(computed_at)
ORDER BY (tool_name, model, computed_at);
```

### `infra.patrol_efficiency`
**Source**: `token-efficiency.md`

```sql
CREATE TABLE infra.patrol_efficiency (
    session_id        LowCardinality(String),
    patrol_start      DateTime64(3),
    patrol_end        DateTime64(3),
    agents_dispatched UInt8,
    tool_calls        UInt16,
    dispatch_calls    UInt8,
    monitor_calls     UInt8,
    decision_calls    UInt8,
    total_input_tokens  UInt32,
    total_output_tokens UInt32,
    total_tokens        UInt32,
    total_cost          Float64,
    output_input_ratio  Float64,
    dispatch_overhead   Float64,
    tokens_per_agent    Float64,
    cost_per_agent      Float64,
    outcome             LowCardinality(String),
    patrol_duration_s   UInt32,
    efficiency_grade    LowCardinality(String),
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (patrol_start, session_id)
TTL toDate(patrol_start) + INTERVAL 90 DAY;
```

### `infra.decision_efficiency`
**Source**: `token-efficiency.md`

```sql
CREATE TABLE infra.decision_efficiency (
    session_id        LowCardinality(String),
    decision_time     DateTime64(3),
    decision_type     LowCardinality(String),
    confidence        UInt8 DEFAULT 50,
    context_tokens    UInt32,
    decision_tokens   UInt32,
    execution_tokens  UInt32,
    total_decision_cost Float64,
    thinking_ratio    Float64,
    waste_flag        UInt8 DEFAULT 0,
    outcome           LowCardinality(String),
    tool_calls_before UInt8,
    tool_calls_after  UInt8,
    _ingested_at      DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (decision_time, session_id);
```

### `infra.efficiency_waste`
**Source**: `token-efficiency.md`

```sql
CREATE TABLE infra.efficiency_waste (
    detected_at     DateTime64(3),
    session_id      LowCardinality(String),
    waste_type      LowCardinality(String),
    tool_name       LowCardinality(String) DEFAULT '',
    metric          Float64,
    estimated_waste Float64,
    estimated_cost  Float64,
    severity        Enum8('info' = 1, 'warning' = 2, 'critical' = 3),
    detail          String DEFAULT '',
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (detected_at, severity)
TTL toDate(detected_at) + INTERVAL 30 DAY;
```

### `infra.user_events`
**Source**: `user-activity.md`

```sql
CREATE TABLE infra.user_events (
    timestamp       DateTime64(3),
    event_id        String,
    source          LowCardinality(String),
    user_id         String,
    user_display    String,
    activity_type   LowCardinality(String),
    detail          String,
    metadata        Map(String, String)
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), source, user_id)
TTL toDate(timestamp) + INTERVAL 90 DAY
PARTITION BY toDate(timestamp);
```

### `infra.user_activity_hourly` (Materialized View)
**Source**: `user-activity.md`

```sql
CREATE MATERIALIZED VIEW infra.user_activity_hourly
ENGINE = SummingMergeTree
ORDER BY (toStartOfHour(timestamp), user_id, source)
POPULATE AS
SELECT
    toStartOfHour(timestamp) AS hour,
    user_id,
    user_display,
    source,
    count()                   AS event_count,
    countDistinct(activity_type) AS type_count,
    min(timestamp)            AS first_event,
    max(timestamp)            AS last_event
FROM infra.user_events
GROUP BY hour, user_id, user_display, source;
```

### `infra.user_activity_daily` (Materialized View)
**Source**: `user-activity.md`

```sql
CREATE MATERIALIZED VIEW infra.user_activity_daily
ENGINE = SummingMergeTree
ORDER BY (toDate(timestamp), user_id)
POPULATE AS
SELECT
    toDate(timestamp)         AS day,
    user_id,
    user_display,
    source,
    count()                   AS event_count,
    countDistinct(activity_type) AS type_count,
    countDistinct(toStartOfHour(timestamp)) AS active_hours,
    min(timestamp)            AS first_event,
    max(timestamp)            AS last_event,
    dateDiff('minute', min(timestamp), max(timestamp)) AS activity_span_minutes
FROM infra.user_events
GROUP BY day, user_id, user_display, source;
```

### `infra.cc_session_events`
**Source**: `user-activity.md`

```sql
CREATE TABLE infra.cc_session_events (
    timestamp       DateTime64(3),
    session_id      String,
    user_id         String,
    event_type      LowCardinality(String),
    turn_count      UInt32,
    chat_type       LowCardinality(String),
    chat_id         String
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), user_id, session_id)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `infra.feishu_message_events`
**Source**: `user-activity.md`

```sql
CREATE TABLE infra.feishu_message_events (
    timestamp       DateTime64(3),
    message_id      String,
    sender_id       String,
    chat_id         String,
    message_type    LowCardinality(String),
    is_from_user    UInt8,
    content_length  UInt32,
    metadata        Map(String, String)
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), sender_id)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `infra.docker_exec_events`
**Source**: `user-activity.md`

```sql
CREATE TABLE infra.docker_exec_events (
    timestamp       DateTime64(3),
    container       String,
    user            String,
    action          LowCardinality(String),
    exit_code       UInt32,
    command         String
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), user, container)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `infra.image_ages`
**Source**: `base-image-age.md`

```sql
CREATE TABLE infra.image_ages (
    cluster             LowCardinality(String),
    boss_id             String,
    collected_at        DateTime64(3),
    image_name          String,
    image_tag           String,
    image_id            String,
    registry            LowCardinality(String) DEFAULT 'docker.io',
    created_at          DateTime64(3),
    age_days            Float32,
    size_bytes          UInt64,
    base_image          String DEFAULT '',
    base_image_id       String DEFAULT '',
    base_image_created_at DateTime64(3),
    base_image_age_days Float32,
    base_image_drift_days Nullable(Float32),
    last_pull_at        Nullable(DateTime64(3)),
    build_hash          String DEFAULT '',
    build_date          String DEFAULT '',
    in_use              Bool DEFAULT false,
    rebuild_pending     Bool DEFAULT false,
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
PARTITION BY toYYYYMM(collected_at)
ORDER BY (cluster, image_name, collected_at)
TTL collected_at + INTERVAL 180 DAY;
```

### `infra.image_vulnerabilities`
**Source**: `base-image-age.md`

```sql
CREATE TABLE infra.image_vulnerabilities (
    cluster         LowCardinality(String),
    boss_id         String,
    scanned_at      DateTime64(3),
    image_name      String,
    image_tag       String,
    image_id        String DEFAULT '',
    scanner         LowCardinality(String),
    severity        LowCardinality(String),
    count           UInt32,
    top_cves        String DEFAULT '',
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
PARTITION BY toYYYYMM(scanned_at)
ORDER BY (image_name, severity, scanned_at)
TTL scanned_at + INTERVAL 90 DAY;
```

### `infra.image_freshness_policy`
**Source**: `base-image-age.md`

```sql
CREATE TABLE infra.image_freshness_policy (
    image_name      String,
    image_tag       String,
    max_age_days    UInt16,
    max_drift_days  UInt16,
    scan_frequency  LowCardinality(String),
    rebuild_on_cve  Bool DEFAULT true,
    notes           String DEFAULT '',
    _updated_at     DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree
ORDER BY (image_name, image_tag);
```

### `infra.disk_waste_snapshots`
**Source**: `dangling-images.md`

```sql
CREATE TABLE IF NOT EXISTS infra.disk_waste_snapshots (
    boss_id                LowCardinality(String),
    cluster                LowCardinality(String),
    snapshot_time          DateTime64(3),
    images_total           UInt16,
    images_active          UInt16,
    images_size            UInt64,
    images_reclaimable     UInt64,
    dangling_images        UInt16,
    dangling_images_size   UInt64,
    containers_total       UInt16,
    containers_active      UInt16,
    containers_size        UInt64,
    containers_reclaimable UInt64,
    volumes_total          UInt16,
    volumes_active         UInt16,
    volumes_size           UInt64,
    volumes_reclaimable    UInt64,
    build_cache_size       UInt64,
    build_cache_reclaimable UInt64,
    build_cache_entries    UInt16,
    total_waste_bytes      UInt64,
    waste_pct              Float32,
    _ingested_at           DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (snapshot_time, cluster)
TTL snapshot_time + INTERVAL 180 DAY;
```

### `infra.image_tag_inventory`
**Source**: `dangling-images.md`

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
    in_use          UInt8,
    age_days        UInt16
) ENGINE = MergeTree
ORDER BY (snapshot_time, repository, tag)
TTL snapshot_time + INTERVAL 90 DAY;
```

### `infra.delivery_events`
**Source**: `feishu-delivery.md`

```sql
CREATE TABLE infra.delivery_events (
    timestamp     DateTime64(3),
    message_id    String,
    chat_id       String,
    state         LowCardinality(String),
    category      LowCardinality(String),
    queued_at     DateTime64(3),
    sent_at       DateTime64(3),
    delivered_at  DateTime64(3),
    read_at       DateTime64(3),
    fail_code     String,
    fail_message  String,
    metadata      String
) ENGINE = MergeTree()
ORDER BY (timestamp, state);
```

### `infra.kafka_docker_events` (Kafka Engine)
**Source**: `unified-kafka.md`

```sql
CREATE TABLE infra.kafka_docker_events (
    schema_version   String,
    source           String,
    event_type       String,
    event_time       DateTime64(3),
    producer_host    String,
    producer_cluster String,
    producer_boss_id String,
    payload          String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'docker.events',
    kafka_group_name = 'ck-consumer-docker',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;
```

### `infra.kafka_dlq`
**Source**: `unified-kafka.md`

```sql
CREATE TABLE infra.kafka_dlq (
    topic         String,
    partition     Int32,
    offset        Int64,
    raw_message   String,
    error         String,
    failed_at     DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY failed_at;
```

### `infra.container_stats`
**Source**: `multi-tenancy.md`

```sql
CREATE TABLE IF NOT EXISTS infra.container_stats (
    timestamp           DateTime64(3) CODEC(ZSTD(1)),
    cluster             LowCardinality(String),
    project             LowCardinality(String),
    sandbox             LowCardinality(String),
    container_id        FixedString(12),
    user                LowCardinality(String),
    cpu_percent         Float32,
    memory_usage_bytes  UInt64,
    memory_limit_bytes  UInt64,
    memory_percent      Float32,
    network_rx_bytes    UInt64,
    network_tx_bytes    UInt64,
    block_read_bytes    UInt64,
    block_write_bytes   UInt64,
    pids                UInt16
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (project, timestamp);
```

### `infra.container_events`
**Source**: `multi-tenancy.md`

```sql
CREATE TABLE IF NOT EXISTS infra.container_events (
    timestamp       DateTime64(3) CODEC(ZSTD(1)),
    cluster         LowCardinality(String),
    project         LowCardinality(String),
    sandbox         LowCardinality(String),
    container_id    FixedString(12),
    user            LowCardinality(String),
    event_type      LowCardinality(String),
    exit_code       Nullable(UInt16),
    duration_seconds Nullable(UInt32)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp);
```

### `infra.container_network`
**Source**: `multi-tenancy.md`

```sql
CREATE TABLE IF NOT EXISTS infra.container_network (
    timestamp       DateTime DEFAULT now(),
    cluster         LowCardinality(String),
    project         LowCardinality(String),
    sandbox         LowCardinality(String),
    container_id    FixedString(12),
    network_name    LowCardinality(String),
    ip_address      String,
    peers Nested (
        container_id FixedString(12),
        project      LowCardinality(String),
        sandbox      LowCardinality(String),
        ip_address   String
    )
)
ENGINE = ReplacingMergeTree()
ORDER BY (container_id, network_name);
```

### `infra.container_mounts`
**Source**: `multi-tenancy.md`

```sql
CREATE TABLE IF NOT EXISTS infra.container_mounts (
    timestamp       DateTime DEFAULT now(),
    cluster         LowCardinality(String),
    project         LowCardinality(String),
    sandbox         LowCardinality(String),
    container_id    FixedString(12),
    mount_source    String,
    mount_destination String,
    mount_mode      LowCardinality(String),
    mount_type      LowCardinality(String)
)
ENGINE = ReplacingMergeTree()
ORDER BY (container_id, mount_source);
```

### `infra.access_log`
**Source**: `multi-tenancy.md`

```sql
CREATE TABLE IF NOT EXISTS infra.access_log (
    timestamp       DateTime64(3) CODEC(ZSTD(1)),
    cluster         LowCardinality(String),
    project         LowCardinality(String),
    sandbox         LowCardinality(String),
    container_id    FixedString(12),
    user            LowCardinality(String),
    action          LowCardinality(String),
    cmd             Nullable(String),
    duration_seconds Nullable(UInt32),
    exit_code       Nullable(UInt16),
    source_ip       Nullable(String),
    success         UInt8
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp);
```

### `infra.otel_spans` (cross-container-traces.md version)
**Source**: `cross-container-traces.md`

```sql
CREATE TABLE infra.otel_spans (
    timestamp          DateTime64(9),
    trace_id           String,
    span_id            String,
    parent_span_id     String,
    trace_state        String,
    span_name          String,
    span_kind          LowCardinality(String),
    service_name       String,
    resource_attributes String,
    scope_name         String,
    span_attributes    String,
    duration_ns        Int64,
    status_code        LowCardinality(String),
    status_message     String
) ENGINE = MergeTree()
ORDER BY (service_name, timestamp);
```

---

## Database `cc`

```sql
CREATE DATABASE IF NOT EXISTS cc;
```

### `cc.hook_events`
**Source**: `cc-hooks-direct-ck.md` (definitive version with raw_payload)

```sql
CREATE TABLE IF NOT EXISTS cc.hook_events (
    event_time       DateTime64(3) DEFAULT now64(),
    event_type       LowCardinality(String),
    trace_id         String DEFAULT '',
    msg_id           String DEFAULT '',
    session          String DEFAULT '',
    chat_id          String DEFAULT '',
    sender_id        String DEFAULT '',
    content_len      UInt32 DEFAULT 0,
    has_images       UInt8 DEFAULT 0,
    has_audio        UInt8 DEFAULT 0,
    has_files        UInt8 DEFAULT 0,
    response_len     UInt32 DEFAULT 0,
    turn_duration    Float64 DEFAULT 0,
    input_tokens     UInt32 DEFAULT 0,
    output_tokens    UInt32 DEFAULT 0,
    tools_used       UInt8 DEFAULT 0,
    session_reason   LowCardinality(String) DEFAULT '',
    exit_code        Nullable(Int32),
    permission_request_id String DEFAULT '',
    permission_decision  LowCardinality(String) DEFAULT '',
    raw_payload      String CODEC(ZSTD(3)) DEFAULT '',
    _ingested_at     DateTime DEFAULT now(),
    _ck_instance     LowCardinality(String) DEFAULT 'kyb-infra-clickhouse',
    INDEX idx_raw_payload raw_payload TYPE tokenbf_v1(3072) GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY (toDate(event_time), event_type, msg_id)
TTL toDate(event_time) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

### `cc.session_snapshots`
**Source**: `session-monitor.md`

```sql
CREATE TABLE cc.session_snapshots (
    timestamp       DateTime64(3),
    session_id      String,
    agent_session   String,
    created_at      DateTime64(3),
    last_activity   DateTime64(3),
    turn_count      UInt32,
    message_count   UInt32,
    state           LowCardinality(String),
    chat_type       LowCardinality(String),
    platform        LowCardinality(String),
    user_id         String,
    chat_id         String,
    file_size_bytes UInt32,
    is_corrupted    UInt8
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), session_id)
TTL toDate(timestamp) + INTERVAL 30 DAY;
```

### `cc.session_latest` (Materialized View)
**Source**: `session-monitor.md`

```sql
CREATE MATERIALIZED VIEW cc.session_latest
ENGINE = ReplacingMergeTree(timestamp)
ORDER BY (session_id)
POPULATE AS
SELECT argMax(session_id, timestamp) AS session_id,
       argMax(agent_session, timestamp),
       argMax(created_at, timestamp),
       argMax(last_activity, timestamp),
       argMax(turn_count, timestamp),
       argMax(message_count, timestamp),
       argMax(state, timestamp),
       argMax(chat_type, timestamp),
       argMax(platform, timestamp),
       argMax(user_id, timestamp),
       argMax(chat_id, timestamp),
       argMax(file_size_bytes, timestamp),
       argMax(is_corrupted, timestamp),
       max(timestamp) AS last_seen
FROM cc.session_snapshots
GROUP BY session_id;
```

### `cc.session_events`
**Source**: `session-monitor.md`

```sql
CREATE TABLE cc.session_events (
    timestamp       DateTime64(3),
    event_type      LowCardinality(String),
    session_id      String,
    agent_session   String,
    turn_count      UInt32,
    duration_ms     UInt32,
    error           String,
    metadata        Map(String, String)
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), session_id, event_type)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `cc.intent_metrics`
**Source**: `message-classification.md`

```sql
CREATE TABLE cc.intent_metrics (
    timestamp   DateTime64(3),
    intent      LowCardinality(String),
    chat_id     String,
    sender_id   String,
    chat_type   LowCardinality(String),
    count       UInt32 DEFAULT 1,
    method      LowCardinality(String)
) ENGINE = MergeTree
ORDER BY (toStartOfHour(timestamp), intent, chat_id)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `cc.intent_volume_hourly_mv` (Materialized View)
**Source**: `message-classification.md`

```sql
CREATE MATERIALIZED VIEW cc.intent_volume_hourly_mv
ENGINE = SummingMergeTree
ORDER BY (hour, intent)
POPULATE AS
SELECT
    toStartOfHour(timestamp) AS hour,
    intent,
    count() AS message_count,
    countDistinct(chat_id) AS chat_count,
    countDistinct(sender_id) AS sender_count
FROM cc.intent_metrics
GROUP BY hour, intent;
```

### `cc.message_log` (stdout-parse.md definitive version)
**Source**: `stdout-parse.md`

```sql
CREATE TABLE cc.message_log (
    timestamp        DateTime64(3),
    ingested_at      DateTime64(3) DEFAULT now64(),
    event_type       LowCardinality(String),
    direction        LowCardinality(String),
    log_level        LowCardinality(String),
    log_format       LowCardinality(String),
    msg_id           String,
    session          String,
    chat_id          String,
    sender_id        String,
    agent_session    String,
    request_id       String,
    content_len      UInt32,
    content_text     Nullable(String),
    has_images       UInt8,
    has_audio        UInt8,
    has_files        UInt8,
    message_type     LowCardinality(String),
    response_len     UInt32,
    turn_duration    Float64,
    input_tokens     UInt32,
    output_tokens    UInt32,
    tools_used       UInt8,
    permission_type  LowCardinality(String),
    permission_status LowCardinality(String),
    error_code       LowCardinality(String),
    error_message    String,
    cluster          LowCardinality(String),
    container_name   String,
    host             String,
    payload_raw      String
) ENGINE = MergeTree
ORDER BY (event_time, msg_id)
TTL event_time + INTERVAL 90 DAY;

ALTER TABLE cc.message_log ADD INDEX IF NOT EXISTS idx_msg_id msg_id TYPE set(100) GRANULARITY 1;
ALTER TABLE cc.message_log ADD INDEX IF NOT EXISTS idx_chat_id chat_id TYPE set(100) GRANULARITY 4;
```

### `cc.kafka_queue` (Kafka Engine)
**Source**: `kafka-message-bus.md`

```sql
CREATE TABLE cc.kafka_queue (
    event_time      DateTime64(3),
    source          String,
    event_type      String,
    msg_id          String,
    session         String,
    agent_session   String,
    user            String,
    platform        String,
    content_len     UInt32,
    has_images      UInt8,
    has_audio       UInt8,
    has_files       UInt8,
    tools           UInt8,
    response_len    UInt32,
    turn_duration   Float64,
    input_tokens    UInt32,
    output_tokens   UInt32,
    request_id      String,
    tool            String,
    elapsed_sec     Float64,
    payload_raw     String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'cc.events',
    kafka_group_name = 'ck-consumer-cc',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3;
```

### `cc.kafka_to_message_log` (Materialized View, Kafka -> MergeTree)
**Source**: `kafka-message-bus.md`

```sql
CREATE MATERIALIZED VIEW cc.kafka_to_message_log TO cc.message_log AS
SELECT *
FROM cc.kafka_queue;
```

### `cc.ws_kafka` (Kafka Engine)
**Source**: `proxy-kafka.md`

```sql
CREATE TABLE cc.ws_kafka (
    conn_id         String,
    stream          LowCardinality(String),
    direction       LowCardinality(String),
    opcode          LowCardinality(String),
    frame_len       UInt32,
    frame_seq       UInt64,
    payload_truncated UInt8,
    payload_sha256  FixedString(64),
    msg_id          String,
    event_time      DateTime64(9),
    source          LowCardinality(String),
    event_type      LowCardinality(String),
    producer_host   LowCardinality(String),
    producer_instance String,
    proxy_version   String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'proxy.ws_frames',
    kafka_group_name = 'ck-consumer-ws',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3;
```

### `cc.ws_frames`
**Source**: `sidecar-intercept.md`

```sql
CREATE TABLE cc.ws_frames (
    ts              DateTime64(9),
    stream          LowCardinality(String),
    direction       LowCardinality(String),
    opcode          LowCardinality(String),
    frame_len       UInt32,
    payload_truncated UInt8,
    payload_sha256   FixedString(64),
    msg_id          String,
    payload         String,
    frame_seq       UInt64,
    conn_id         String,
    proxy_hostname  LowCardinality(String),
    sidecar         LowCardinality(String) DEFAULT 'feishu-ws-cap',
    _ingested_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(ts), conn_id, frame_seq)
TTL toDate(ts) + INTERVAL 90 DAY;
```

---

## Database `patrol`

```sql
CREATE DATABASE IF NOT EXISTS patrol;
```

### `patrol.event_log`
**Source**: `kafka-message-bus.md`

```sql
CREATE TABLE patrol.event_log (
    event_time      DateTime64(3),
    source          LowCardinality(String),
    event_type      LowCardinality(String),
    patrol_id       LowCardinality(String),
    status          LowCardinality(String),
    uptime_sec      UInt32,
    disk_usage_pct  Float32,
    severity        LowCardinality(String),
    category        LowCardinality(String),
    detail          String,
    payload_raw     String
) ENGINE = MergeTree
ORDER BY (event_time)
TTL event_time + INTERVAL 90 DAY;
```

### `patrol.kafka_queue` (Kafka Engine)
**Source**: `kafka-message-bus.md`

```sql
CREATE TABLE patrol.kafka_queue (
    event_time      DateTime64(3),
    source          String,
    event_type      String,
    patrol_id       String,
    status          String,
    uptime_sec      UInt32,
    disk_usage_pct  Float32,
    severity        String,
    category        String,
    detail          String,
    payload_raw     String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'patrol.events',
    kafka_group_name = 'ck-consumer-patrol',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;
```

### `patrol.kafka_to_event_log` (Materialized View)
**Source**: `kafka-message-bus.md`

```sql
CREATE MATERIALIZED VIEW patrol.kafka_to_event_log TO patrol.event_log AS
SELECT *
FROM patrol.kafka_queue;
```

### `patrol.health_checks`
**Source**: `vector-pipeline.md`

```sql
CREATE TABLE patrol.health_checks (
    timestamp           DateTime64(3),
    ingested_at         DateTime64(3) DEFAULT now64(),
    patrol_id           LowCardinality(String),
    cycle               UInt64,
    status              LowCardinality(String),
    containers_healthy  String,
    containers_running  UInt16,
    containers_total    UInt16,
    disk_used_pct       UInt8,
    detail              String,
    cluster             LowCardinality(String),
    container_name      String,
    host                String
) ENGINE = MergeTree
ORDER BY (patrol_id, timestamp)
TTL timestamp + INTERVAL 30 DAY;
```

---

## Database `boss`

```sql
CREATE DATABASE IF NOT EXISTS boss;
```

### `boss.agent_log`
**Source**: `vector-pipeline.md`

```sql
CREATE TABLE boss.agent_log (
    timestamp       DateTime64(3),
    ingested_at     DateTime64(3) DEFAULT now64(),
    content         String,
    level           LowCardinality(String),
    has_error       UInt8 DEFAULT 0,
    has_critical    UInt8 DEFAULT 0,
    has_panic       UInt8 DEFAULT 0,
    error_keyword   String,
    cluster         LowCardinality(String),
    container_name  String,
    host            String
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), has_error, has_critical)
TTL toDate(timestamp) + INTERVAL 7 DAY;
```

---

## Database `mcp`

```sql
CREATE DATABASE IF NOT EXISTS mcp;
```

### `mcp.request_log`
**Source**: `vector-pipeline.md`

```sql
CREATE TABLE mcp.request_log (
    timestamp       DateTime64(3),
    ingested_at     DateTime64(3) DEFAULT now64(),
    event           LowCardinality(String),
    server          LowCardinality(String),
    tool            String,
    params_size     UInt32,
    latency_ms      UInt32,
    output_size     UInt32,
    status          LowCardinality(String),
    error           String,
    retry_count     UInt8,
    cluster         LowCardinality(String),
    container_name  String,
    host            String
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), server, tool)
TTL toDate(timestamp) + INTERVAL 30 DAY;
```

---

## Database `net`

```sql
CREATE DATABASE IF NOT EXISTS net;
```

### `net.connection_log`
**Source**: `network-compliance.md`

```sql
CREATE TABLE net.connection_log (
    timestamp       DateTime64(6) DEFAULT now64(),
    event_type      String,
    src_ip          IPv4,
    src_port        UInt16,
    dst_ip          IPv4,
    dst_port        UInt16,
    protocol        String,
    bytes_in        UInt64,
    bytes_out       UInt64,
    packets_in      UInt64,
    packets_out     UInt64,
    src_container   LowCardinality(String),
    dst_container   LowCardinality(String),
    allowlist_match Enum8('yes'=1, 'no'=0, 'unknown'=-1),
    connection_duration_ms UInt64,
    cluster         LowCardinality(String),
    tags            Array(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, src_container, dst_container)
TTL timestamp + INTERVAL 90 DAY DELETE
SETTINGS index_granularity = 8192;
```

### `net.port_scan`
**Source**: `network-compliance.md`

```sql
CREATE TABLE net.port_scan (
    timestamp       DateTime DEFAULT now(),
    scan_id         UUID,
    target_ip       IPv4,
    target_container LowCardinality(String),
    port            UInt16,
    protocol        String,
    state           String,
    service         String,
    expected        Enum8('yes'=1, 'no'=0),
    cluster         LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, target_container, port)
TTL timestamp + INTERVAL 90 DAY DELETE;
```

### `net.container_inventory`
**Source**: `network-compliance.md`

```sql
CREATE TABLE net.container_inventory (
    timestamp       DateTime DEFAULT now(),
    container_name  LowCardinality(String),
    container_id    String,
    ip_address      IPv4,
    image           String,
    status          String,
    networks        Array(String),
    ports           Array(Tuple(UInt16, String)),
    cluster         LowCardinality(String)
)
ENGINE = ReplacingMergeTree(timestamp)
ORDER BY container_name
SETTINGS index_granularity = 8192;
```

### `net.allowlist`
**Source**: `network-compliance.md`

```sql
CREATE TABLE net.allowlist (
    updated_at      DateTime DEFAULT now(),
    source          LowCardinality(String),
    destination     LowCardinality(String),
    port            UInt16,
    protocol        String,
    purpose         String,
    enabled         UInt8 DEFAULT 1
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (source, destination, port);
```

### `net.unauthorized_access`
**Source**: `network-compliance.md`

```sql
CREATE TABLE net.unauthorized_access (
    timestamp       DateTime DEFAULT now(),
    src_container   LowCardinality(String),
    dst_container   LowCardinality(String),
    dst_port        UInt16,
    protocol        String,
    reason          String,
    first_seen      DateTime,
    last_seen       DateTime,
    occurrence_count UInt64,
    acknowledged    UInt8 DEFAULT 0,
    acknowledged_by String DEFAULT '',
    cluster         LowCardinality(String)
)
ENGINE = ReplacingMergeTree(timestamp)
ORDER BY (src_container, dst_container, dst_port);
```

### `net.firewall_hit`
**Source**: `network-compliance.md`

```sql
CREATE TABLE net.firewall_hit (
    timestamp       DateTime64(3),
    source_ip       IPv4,
    dest_ip         IPv4,
    dest_port       UInt16,
    protocol        String,
    action          String,
    chain           String,
    prefix          String,
    in_interface    String,
    out_interface   String
) ENGINE = MergeTree
ORDER BY (timestamp, source_ip, dest_ip, dest_port);
```

### `net.kafka_queue` (Kafka Engine)
**Source**: `unified-kafka.md`

```sql
CREATE TABLE net.kafka_queue (
    schema_version   String,
    source           String,
    event_type       String,
    event_time       DateTime64(3),
    producer_host    String,
    producer_instance String,
    payload          String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'net.events',
    kafka_group_name = 'ck-consumer-net',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1;
```

### `net.outbound_snapshot`
**Source**: `sing-box-metrics.md`

```sql
CREATE TABLE net.outbound_snapshot (
    event_time          DateTime         COMMENT 'Snapshot timestamp',
    outbound_tag        LowCardinality(String) COMMENT 'Outbound tag',
    active_connections  UInt16           COMMENT 'Currently active connections',
    bytes_upload_total  UInt64           COMMENT 'Cumulative upload bytes',
    bytes_download_total UInt64          COMMENT 'Cumulative download bytes',
    upload_speed_bps    UInt64           COMMENT 'Upload speed in bytes/sec',
    download_speed_bps  UInt64           COMMENT 'Download speed in bytes/sec'
) ENGINE = MergeTree
ORDER BY (event_time, outbound_tag)
TTL event_time + INTERVAL 7 DAY;
```

### `net.latency`
**Source**: `sing-box-metrics.md`

```sql
CREATE TABLE net.latency (
    event_time      DateTime         COMMENT 'Probe timestamp',
    node_tag        LowCardinality(String) COMMENT 'Node tag',
    group_tag       LowCardinality(String) COMMENT 'Parent group',
    node_type       LowCardinality(String) COMMENT 'Node type',
    latency_ms      Nullable(UInt16) COMMENT 'Round-trip latency in ms',
    alive           UInt8            COMMENT 'Node is alive? 1 = yes, 0 = no'
) ENGINE = MergeTree
ORDER BY (event_time, group_tag, node_tag)
TTL event_time + INTERVAL 90 DAY;
```

---

## Database `monitor`

```sql
CREATE DATABASE IF NOT EXISTS monitor;
```

### `monitor.container_metrics`
**Source**: `cadvisor-metrics.md`

```sql
CREATE TABLE monitor.container_metrics
(
    event_time      DateTime64(3),
    container_name  LowCardinality(String),
    container_image LowCardinality(String),
    metric_name     LowCardinality(String),
    labels          Map(LowCardinality(String), String),
    value           Float64,
    scrape_interval UInt32
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, container_name, metric_name)
TTL event_time + INTERVAL 90 DAY DELETE
SETTINGS index_granularity = 8192;
```

### `monitor.container_metrics_hourly`
**Source**: `cadvisor-metrics.md`

```sql
CREATE TABLE monitor.container_metrics_hourly
(
    event_hour      DateTime,
    container_name  LowCardinality(String),
    metric_name     LowCardinality(String),
    metric_type     LowCardinality(String),
    labels          Map(LowCardinality(String), String),
    avg_val         Float64,
    min_val         Float64,
    max_val         Float64,
    p50_val         Float64,
    p95_val         Float64,
    p99_val         Float64,
    sample_count    UInt32
)
ENGINE = SummingMergeTree
PARTITION BY toYYYYMM(event_hour)
ORDER BY (event_hour, container_name, metric_name, labels)
TTL event_hour + INTERVAL 365 DAY DELETE;
```

### `monitor.container_metrics_daily`
**Source**: `cadvisor-metrics.md`

```sql
CREATE TABLE monitor.container_metrics_daily
(
    event_date      Date,
    container_name  LowCardinality(String),
    metric_name     LowCardinality(String),
    metric_type     LowCardinality(String),
    labels          Map(LowCardinality(String), String),
    avg_val         Float64,
    min_val         Float64,
    max_val         Float64,
    p50_val         Float64,
    p95_val         Float64,
    p99_val         Float64,
    sample_count    UInt32
)
ENGINE = SummingMergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, container_name, metric_name, labels)
TTL event_date + INTERVAL 3 YEAR DELETE;
```

### `monitor.backup_snapshots`
**Source**: `backup-monitor.md`

```sql
CREATE TABLE monitor.backup_snapshots (
    timestamp           DateTime64(3),
    pg_age_seconds      Int32,
    pg_size_bytes       UInt64,
    pg_integrity        LowCardinality(String),
    pg_status           LowCardinality(String),
    ck_age_seconds      Int32,
    ck_size_bytes       UInt64,
    ck_integrity        LowCardinality(String),
    ck_status           LowCardinality(String),
    config_age_seconds  Int32,
    config_size_bytes   UInt64,
    config_integrity    LowCardinality(String),
    config_status       LowCardinality(String),
    host_disk_usage_pct Float32,
    overall_status      LowCardinality(String)
) ENGINE = MergeTree
ORDER BY (toDate(timestamp))
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

---

## Database `otel`

```sql
CREATE DATABASE IF NOT EXISTS otel;
```

### `otel.traces_raw`
**Source**: `otel-kafka-vector.md` (appendix deployment version)

```sql
CREATE TABLE otel.traces_raw (
    timestamp           DateTime64(9),
    trace_id            String,
    span_id             String,
    parent_span_id      String,
    span_name           String,
    span_kind           Int32,
    service_name        String,
    resource_attributes Map(String, String),
    span_attributes     Map(String, String),
    status_code         Int32,
    status_message      String,
    events              Array(Tuple(time_delta DateTime64(9), name String, attributes Map(String, String))),
    links               Array(Tuple(trace_id String, span_id String, trace_state String, attributes Map(String, String))),
    duration_ns         Int64,
    ingested_at         DateTime64(3),
    _topic              String,
    _partition          Int32,
    _offset             Int64,
    raw_body            String
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (trace_id, timestamp)
TTL timestamp + INTERVAL 90 DAY;
```

### `otel.metrics_raw`
**Source**: `otel-kafka-vector.md`

```sql
CREATE TABLE otel.metrics_raw (
    timestamp           DateTime64(9),
    resource_attributes Map(String, String),
    metric_name         String,
    metric_description  String,
    metric_unit         String,
    metric_type         Int32,
    value_double        Float64,
    value_int           Int64,
    count               Int64,
    sum                 Float64,
    min                 Float64,
    max                 Float64,
    bucket_bounds       Array(Float64),
    bucket_counts       Array(Int64),
    attributes          Map(String, String),
    ingested_at         DateTime64(3),
    _topic              String,
    _partition          Int32,
    _offset             Int64,
    raw_body            String
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (metric_name, timestamp)
TTL timestamp + INTERVAL 90 DAY;
```

### `otel.logs_raw`
**Source**: `otel-kafka-vector.md`

```sql
CREATE TABLE otel.logs_raw (
    timestamp           DateTime64(9),
    trace_id            String,
    span_id             String,
    severity_text       String,
    severity_number     Int32,
    body                String,
    resource_attributes Map(String, String),
    log_attributes      Map(String, String),
    ingested_at         DateTime64(3),
    _topic              String,
    _partition          Int32,
    _offset             Int64,
    raw_body            String
) ENGINE = MergeTree
PARTITION BY toDate(timestamp)
ORDER BY (timestamp, trace_id)
TTL timestamp + INTERVAL 90 DAY;
```

---

## Database `kyb`

```sql
CREATE DATABASE IF NOT EXISTS kyb;
```

### `kyb.otel_spans`
**Source**: `otel-vector.md`

```sql
CREATE TABLE kyb.otel_spans (
    timestamp           DateTime64(9),
    trace_id            String,
    span_id             String,
    parent_span_id      String DEFAULT '',
    trace_state         String DEFAULT '',
    span_name           String,
    span_kind           LowCardinality(String),
    status_code         LowCardinality(String),
    status_message      String DEFAULT '',
    duration_nanos      UInt64,
    service_name        LowCardinality(String),
    feishu_msg_id       String DEFAULT '',
    feishu_chat_id      String DEFAULT '',
    cc_session          String DEFAULT '',
    input_tokens        UInt32 DEFAULT 0,
    output_tokens       UInt32 DEFAULT 0,
    span_attributes     Map(String, String) DEFAULT {},
    span_events         Array(Tuple(
        event_timestamp DateTime64(9),
        event_name     String,
        event_attributes Map(String, String)
    )) DEFAULT [],
    cluster             LowCardinality(String),
    environment         LowCardinality(String),
    host_name           String DEFAULT '',
    container_id        String DEFAULT '',
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), service_name, trace_id)
PARTITION BY toDate(timestamp)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `kyb.otel_metrics`
**Source**: `otel-vector.md`

```sql
CREATE TABLE kyb.otel_metrics (
    timestamp           DateTime64(9),
    service_name        LowCardinality(String),
    metric_name         String,
    metric_type         LowCardinality(String),
    metric_value        Float64,
    histogram_count     UInt64 DEFAULT 0,
    histogram_sum       Float64 DEFAULT 0,
    histogram_buckets   Array(Tuple(
        bucket_boundary Float64,
        bucket_count    UInt64
    )) DEFAULT [],
    tags                Map(String, String) DEFAULT {},
    cluster             LowCardinality(String),
    environment         LowCardinality(String),
    host_name           String DEFAULT '',
    container_id        String DEFAULT '',
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), service_name, metric_name)
PARTITION BY toDate(timestamp)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `kyb.otel_logs`
**Source**: `otel-vector.md`

```sql
CREATE TABLE kyb.otel_logs (
    timestamp           DateTime64(9),
    trace_id            String DEFAULT '',
    span_id             String DEFAULT '',
    severity_text       LowCardinality(String),
    severity_number     UInt8 DEFAULT 9,
    body                String,
    service_name        LowCardinality(String),
    log_attributes      Map(String, String) DEFAULT {},
    cluster             LowCardinality(String),
    environment         LowCardinality(String),
    host_name           String DEFAULT '',
    container_id        String DEFAULT '',
    _ingested_at        DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), service_name, severity_text)
PARTITION BY toDate(timestamp)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `kyb.model_pricing`
**Source**: `model-usage.md`

```sql
CREATE TABLE kyb.model_pricing (
    model_pattern        String,
    model_tier           LowCardinality(String),
    input_cost_per_mtok  Decimal(10,4),
    output_cost_per_mtok Decimal(10,4),
    effective_from       Date,
    effective_to         Date DEFAULT '2099-12-31'
)
ENGINE = ReplacingMergeTree
ORDER BY (model_pattern, effective_from);
```

### `kyb.sessions`
**Source**: `session-duration.md`

```sql
CREATE TABLE IF NOT EXISTS kyb.sessions (
    session_id       String,
    container_id     String,
    provenance       Enum8('cold' = 1, 'resume' = 2),
    container_life   UInt64,
    state            String,
    state_changed_at DateTime,
    project          String,
    branch           String,
    model            String,
    user             String,
    hostname         String,
    pid              UInt32,
    created_at       DateTime,
    started_at       DateTime,
    destroyed_at     Nullable(DateTime),
    duration_seconds Nullable(UInt32),
    idle_seconds     Nullable(UInt32),
    exit_code        Nullable(UInt16),
    exit_reason      Nullable(String),
    parent_session_id Nullable(String),
    dispatch_depth    UInt8 DEFAULT 0,
    tasks_completed  UInt16 DEFAULT 0,
    tasks_failed     UInt16 DEFAULT 0,
    timestamp        DateTime
) ENGINE = MergeTree()
ORDER BY (project, timestamp)
PARTITION BY toYYYYMM(timestamp);
```

### `kyb.session_events`
**Source**: `session-duration.md`

```sql
CREATE TABLE IF NOT EXISTS kyb.session_events (
    session_id     String,
    event_type     Enum8(
        'start'    = 1,
        'complete' = 2,
        'idle'     = 3,
        'resume'   = 4,
        'timeout'  = 5,
        'error'    = 6
    ),
    event_time     DateTime64(3),
    duration_ms    UInt32 DEFAULT 0,
    detail         String DEFAULT ''
) ENGINE = MergeTree()
ORDER BY (session_id, event_time);
```

### `kyb.tengu_tool_use`
**Source**: `claude-telemetry.md`

```sql
CREATE TABLE kyb.tengu_tool_use (
    tengu_version    LowCardinality(String),
    event_id         String,
    timestamp        DateTime64(3),
    session_id       String,
    agent_id         String,
    agent_type       LowCardinality(String),
    project          LowCardinality(String),
    environment      LowCardinality(String),
    phase            Enum8('start' = 1, 'end' = 2),
    tool_name        LowCardinality(String),
    tool_category    LowCardinality(String),
    input_summary    String,
    output_summary   String,
    input_token_est  UInt32,
    output_token_est UInt32,
    duration_ms      UInt32,
    success          Bool,
    error_type       LowCardinality(String),
    error_message    String,
    metadata         Map(String, String)
)
ENGINE = MergeTree
ORDER BY (session_id, timestamp)
PARTITION BY toYYYYMM(timestamp)
TTL toDate(timestamp) + toIntervalDay(90)
SETTINGS index_granularity = 8192;
```

### `kyb.tengu_session`
**Source**: `claude-telemetry.md`

```sql
CREATE TABLE kyb.tengu_session (
    tengu_version        LowCardinality(String),
    event_id             String,
    timestamp            DateTime64(3),
    session_id           String,
    agent_id             String,
    agent_type           LowCardinality(String),
    project              LowCardinality(String),
    environment          LowCardinality(String),
    phase                Enum8('start' = 1, 'end' = 2, 'heartbeat' = 3),
    model                LowCardinality(String),
    project_dir          String,
    tool_count           UInt32,
    error_count          UInt32,
    duration_seconds     UInt32,
    total_input_tokens   UInt32,
    total_output_tokens  UInt32,
    cost_est_usd         Float32,
    stop_reason          LowCardinality(String),
    metadata             Map(String, String)
)
ENGINE = MergeTree
ORDER BY (session_id, timestamp)
PARTITION BY toYYYYMM(timestamp)
TTL toDate(timestamp) + toIntervalDay(365)
SETTINGS index_granularity = 8192;
```

### `kyb.tengu_error`
**Source**: `claude-telemetry.md`

```sql
CREATE TABLE kyb.tengu_error (
    tengu_version    LowCardinality(String),
    event_id         String,
    timestamp        DateTime64(3),
    session_id       String,
    agent_id         String,
    agent_type       LowCardinality(String),
    project          LowCardinality(String),
    environment      LowCardinality(String),
    tool_name        LowCardinality(String),
    tool_category    LowCardinality(String),
    error_class      LowCardinality(String),
    error_subclass   LowCardinality(String),
    error_message    String,
    exit_code        Int16,
    is_transient     Bool,
    is_known         Bool,
    suggestion       String,
    metadata         Map(String, String)
)
ENGINE = MergeTree
ORDER BY (timestamp, error_class)
PARTITION BY toYYYYMM(timestamp)
TTL toDate(timestamp) + toIntervalDay(90)
SETTINGS index_granularity = 8192;
```

### `kyb.mv_tool_latency_daily` (Materialized View)
**Source**: `claude-telemetry.md`

```sql
CREATE MATERIALIZED VIEW kyb.mv_tool_latency_daily
ENGINE = AggregatingMergeTree
ORDER BY (day, tool_category, tool_name)
AS SELECT
    toDate(timestamp) AS day,
    tool_category,
    tool_name,
    countState() AS calls,
    quantileState(0.5)(duration_ms) AS p50_ms,
    quantileState(0.9)(duration_ms) AS p90_ms,
    quantileState(0.99)(duration_ms) AS p99_ms,
    avgState(duration_ms) AS avg_ms,
    sumState(COALESCE(input_token_est, 0)) AS total_input_tokens,
    sumState(COALESCE(output_token_est, 0)) AS total_output_tokens
FROM kyb.tengu_tool_use
WHERE phase = 'end'
GROUP BY day, tool_category, tool_name;
```

### `kyb.mv_error_rate_hourly` (Materialized View)
**Source**: `claude-telemetry.md`

```sql
CREATE MATERIALIZED VIEW kyb.mv_error_rate_hourly
ENGINE = AggregatingMergeTree
ORDER BY (hour, error_class)
AS SELECT
    toStartOfHour(timestamp) AS hour,
    error_class,
    countState() AS total,
    uniqState(session_id) AS affected_sessions,
    uniqState(tool_name) AS affected_tools
FROM kyb.tengu_error
GROUP BY hour, error_class;
```

### `kyb.mv_session_summary_daily` (Materialized View)
**Source**: `claude-telemetry.md`

```sql
CREATE MATERIALIZED VIEW kyb.mv_session_summary_daily
ENGINE = AggregatingMergeTree
ORDER BY (day, agent_type)
AS SELECT
    toDate(timestamp) AS day,
    agent_type,
    countState() AS sessions,
    avgState(duration_seconds) AS avg_duration_sec,
    sumState(tool_count) AS total_tools,
    sumState(error_count) AS total_errors,
    sumState(cost_est_usd) AS total_cost_est
FROM kyb.tengu_session
WHERE phase IN ('start', 'end')
GROUP BY day, agent_type;
```

### `kyb.tls_cert_checks`
**Source**: `tls-cert-monitor.md`

```sql
CREATE TABLE IF NOT EXISTS kyb.tls_cert_checks (
    timestamp   DateTime64(3) DEFAULT now(),
    target      LowCardinality(String),
    hostname    String,
    port        UInt16,
    status      LowCardinality(String),
    days_left   Int16,
    not_before  String,
    not_after   String,
    issuer      String,
    error       String
)
ENGINE = ReplacingMergeTree
ORDER BY (toDate(timestamp), target, hostname, port)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

### `kyb.kafka_hooks_queue` (Kafka Engine)
**Source**: `unified-kafka.md`

```sql
CREATE TABLE kyb.kafka_hooks_queue (
    schema_version       String,
    source               String,
    event_type           String,
    event_time           DateTime64(3),
    producer_host        String,
    producer_session_id  String,
    producer_agent_id    String,
    payload              String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'hooks.events',
    kafka_group_name = 'ck-consumer-hooks',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3;
```

---

## Database `feishu`

```sql
CREATE DATABASE IF NOT EXISTS feishu;
```

### `feishu.webhook_events`
**Source**: `feishu-webhook-intercept.md`

```sql
CREATE TABLE feishu.webhook_events (
    event_id     String,
    event_type   String,
    app_id       String,
    create_time  DateTime64(3),
    received_at  DateTime64(3),
    header       String,
    event_body   String,
    signature    String,
    retry_of     Nullable(String)
) ENGINE = MergeTree()
ORDER BY (event_type, create_time);
```

---

## No-Database Tables

These tables are defined without an explicit `CREATE DATABASE` prefix. Assume `infra` database.

### `image_vulnerabilities` (vuln-scan.md)
**Source**: `vuln-scan.md`

```sql
CREATE TABLE image_vulnerabilities (
    scan_id           UUID,
    scanned_at        DateTime64(3, 'Asia/Shanghai'),
    scanner           LowCardinality(String),
    image_name        String,
    image_tag         String,
    image_digest      String,
    image_full_ref    String,
    cve_id            String,
    package_name      String,
    package_version   String,
    fixed_version     String,
    severity          LowCardinality(String),
    severity_score    Float32,
    cve_published_at  Date,
    cve_description   String,
    pkg_type          LowCardinality(String),
    is_fixable        UInt8,
    fix_available     UInt8 DEFAULT 0,
    _inserted_at      DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(scanned_at)
ORDER BY (scanned_at, image_name, severity, cve_id)
TTL scanned_at + INTERVAL 180 DAY;
```

### `image_scan_summary` (vuln-scan.md)
**Source**: `vuln-scan.md`

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
    fixable_count     UInt32,
    unfixed_count     UInt32,
    scan_duration_ms  UInt32,
    _inserted_at      DateTime DEFAULT now()
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(scanned_at)
ORDER BY (scanned_at, image_full_ref);
```

### `image_fix_age` (vuln-scan.md)
**Source**: `vuln-scan.md`

```sql
CREATE TABLE image_fix_age (
    image_name        String,
    image_digest      String,
    cve_id            String,
    cve_published_at  Date,
    first_seen_at     DateTime64(3, 'Asia/Shanghai'),
    fixed_at          DateTime64(3, 'Asia/Shanghai'),
    fix_age_hours     UInt32,
    image_fix_version String,
    _inserted_at      DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_inserted_at)
ORDER BY (image_name, cve_id, first_seen_at);
```

---

## Deprecated / Duplicate Tables (Not Included)

The following tables defined in review docs are noted but **not included** in this migration because they are duplicates, superseded, or non-ClickHouse:

| Table | Source | Reason |
|-------|--------|--------|
| `infra.incident_slo_compliance_mv` | `incident-slo.md` §3.3 | Superseded by `infra.incident_slo_daily_mv` in same doc appendix |
| `delivery_tracking` | `feishu-delivery.md` | SQLite, not ClickHouse |
| `infra.delivery_metrics_mv` | `feishu-delivery.md` | Incomplete DDL (placeholder only) |
| `infra.post_mortems_monthly_mv` | `postmortem.md` | MV references `infra.action_items` which exists |
| `infra.action_items_aging_mv` | `postmortem.md` | MV references `infra.action_items` which exists |
| `cc.kafka_queue` (unified-kafka.md) | `unified-kafka.md` | Different schema from `kafka-message-bus.md` version — use the kafka-message-bus version |
| `infra.container_stats_daily` | `multi-tenancy.md` | MV, depends on `infra.container_stats` |

---

## Execution Order

1. **Databases first** (all `CREATE DATABASE IF NOT EXISTS` at top of each section)
2. **Regular tables** (MergeTree, ReplacingMergeTree, etc.)
3. **Kafka Engine tables** (depends on Kafka being available)
4. **Materialized Views** (depends on source tables existing)

> **Generated**: 2026-05-23  
> **Total tables**: ~150+ across 11 databases  
> **Source**: Consolidated from 50+ `docs/infra/reviews/*.md` files
