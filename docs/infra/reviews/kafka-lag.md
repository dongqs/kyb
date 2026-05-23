---
decision: 不应该做
---

# Kafka Consumer Lag Monitoring

**Status**: Design proposal
**Date**: 2026-05-23
**Author**: boss

---

## 1. Motivation

The Kafka message bus design (`kafka-message-bus.md`) establishes Kafka as the central event bus for observability, with ClickHouse Kafka Engine tables as the consumer. This introduces a critical operational blind spot: **consumer lag**.

Consumer lag is the difference between the latest message in a Kafka partition and the last message the consumer has committed. When lag grows unchecked:

1. **Data staleness** -- Grafana dashboards powered by ClickHouse show stale data because events are queued in Kafka, not yet ingested.
2. **Silent data loss** -- if lag exceeds the topic retention window (7 days), unconsumed messages are deleted before the consumer can read them. Events are permanently lost.
3. **Rebalance storms** -- a consumer group that is too slow triggers repeated rebalances, further stalling consumption and amplifying lag.
4. **Recovery time blindness** -- when ClickHouse resumes after an outage, operators do not know how far behind the consumer is or how long it will take to catch up.

The root cause is that **ClickHouse Kafka Engine tables do not expose consumer lag as a queryable metric**. The CK Kafka Engine manages its own internal consumer inside the ClickHouse process -- it does not register with any external consumer lag monitoring tool. Lag is invisible until data stops appearing in dashboards.

This document defines how to measure, visualize, and alert on Kafka consumer lag for the kyb-infra observability pipeline.

---

## 2. Metrics

### 2.1 Core Lag Metrics

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `kafka_consumer_lag` | gauge | Redpanda `/metrics` | Messages behind per (topic, partition, consumer_group) |
| `kafka_consumer_offset` | gauge | Redpanda `/metrics` | Current committed offset per partition |
| `kafka_partition_offset` | gauge | Redpanda `/metrics` | High-water mark per partition |
| `kafka_consumer_lag_seconds` | gauge | Derived | Estimated time to catch up: `lag / avg_consume_rate` |
| `kafka_consumer_lag_pct` | gauge | Derived | Lag as fraction of retention window: `lag / (retention_msgs)` |

### 2.2 Consumer Group Metrics

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `kafka_consumer_group_members` | gauge | Redpanda `/metrics` | Number of active members in group |
| `kafka_consumer_group_rebalance_count` | counter | Redpanda `/metrics` | Total rebalance events (cumulative) |
| `kafka_consumer_group_rebalance_duration_seconds` | gauge | Redpanda `/metrics` | Duration of last rebalance |
| `kafka_consumer_group_assignment` | gauge | Redpanda `/metrics` | Partition-to-member assignment (1 if assigned, 0 otherwise) |

### 2.3 Partition Metrics

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `kafka_partition_under_replicated` | gauge | Redpanda `/metrics` | 1 if partition is under-replicated |
| `kafka_partition_leader` | gauge | Redpanda `/metrics` | Broker ID of partition leader |
| `kafka_log_size_bytes` | gauge | Redpanda `/metrics` | Total log size per partition |

### 2.4 Redpanda Broker Health

| Metric | Type | Source | Description |
|--------|------|--------|-------------|
| `redpanda_cpu_usage_ratio` | gauge | Redpanda `/metrics` | CPU utilization (0-1) |
| `redpanda_memory_usage_bytes` | gauge | Redpanda `/metrics` | Memory used |
| `redpanda_disk_usage_bytes` | gauge | Redpanda `/metrics` | Disk used per partition |
| `redpanda_throughput_bytes_in` | counter | Redpanda `/metrics` | Bytes written (cumulative) |
| `redpanda_throughput_bytes_out` | counter | Redpanda `/metrics` | Bytes read (cumulative) |

---

## 3. Architecture

### 3.1 Collection Pipeline

```
┌──────────────────┐      ┌──────────────────┐      ┌─────────────┐
│   Redpanda       │─────>│   Prometheus      │─────>│   Grafana   │
│   (built-in      │      │   (scrape         │      │   Dashboard │
│    /metrics      │      │    endpoint)      │      │   + Alerts  │
│    :9644)        │      │                   │      │             │
└──────────────────┘      │                   │      └─────────────┘
         │                │                   │
         │                │   Alertmanager    │
         │                │   (lag > threshold│
         │                │     fire alert)   │
         │                └──────────────────┘
         ▼
┌──────────────────┐
│   kcat / rpk     │  (ad-hoc debugging, not production collection)
│   consumer groups│
└──────────────────┘
```

**Components**:

| Component | Role |
|-----------|------|
| **Redpanda** | Exposes Prometheus-format metrics at `http://host.orb.internal:9644/metrics` |
| **Prometheus** | Scrapes Redpanda metrics endpoint every 15s. Stores lag time series for alerting and dashboards. |
| **Grafana** | Visualizes lag as time series, heatmaps, and stat panels. Queries Prometheus datasource. |
| **Alertmanager** | Fires alerts when lag exceeds thresholds (see Section 5). |

### 3.2 Key Prometheus Metrics

Redpanda exposes consumer-lag-related metrics. The relevant metric names (Redpanda v24.x+):

```
# Consumer group lag per (topic, partition, group)
redpanda_kafka_consumer_lag{topic="cc.events", partition="0", group="ck-consumer-cc"}

# Committed offset
redpanda_kafka_consumer_offset{topic="cc.events", partition="0", group="ck-consumer-cc"}

# Partition high-water mark
redpanda_kafka_partition_offset{partition="0", topic="cc.events"}

# Consumer group members
redpanda_kafka_consumer_group_members{group="ck-consumer-cc"}

# Consumer group rebalance count (cumulative)
redpanda_kafka_consumer_group_rebalance_count{group="ck-consumer-cc"}

# Partition under-replicated
redpanda_kafka_partition_under_replicated{partition="0", topic="cc.events"}
```

**NOTE**: Redpanda metric names are prefixed with `redpanda_`. If using Apache Kafka with JMX exporter, the same concepts are available under different names (e.g., `kafka_consumer_consumer_group_lag`). Adapt the PromQL queries in Sections 4 and 5 accordingly.

### 3.3 Scrape Configuration

```yaml
# prometheus.yml scrape config
scrape_configs:
  - job_name: 'redpanda'
    scrape_interval: 15s
    scrape_timeout: 10s
    metrics_path: '/metrics'
    static_configs:
      - targets: ['host.orb.internal:9644']
        labels:
          service: kafka
          env: production
```

---

## 4. Grafana Dashboard

### 4.1 Dashboard Layout

**Row 1: Lag Overview** (time-series, 4 panels)

```
┌─────────────────────────────────────────────────────────────┐
│ Panel: Current Lag by Consumer Group        │ Stat: Max Lag │
│ Area chart, one series per (topic, group)    │ (across all   │
│                                             │  groups)      │
├─────────────────────────────────────────────────────────────┤
│ Panel: Lag per Partition                     │ Stat: Lag     │
│ Stacked area, one series per partition       │ Change Rate   │
│ (shows imbalance across partitions)          │ (lag/s,       │
│                                             │  positive=bad) │
├─────────────────────────────────────────────────────────────┤
│ Panel: Committed Offset vs High-Water Mark   │               │
│ Two lines per partition: committed (dashed)  │               │
│ and HW (solid). Gap = lag.                   │               │
└─────────────────────────────────────────────────────────────┘
```

**Row 2: Throughput** (time-series, 3 panels)

```
┌─────────────────────────────────────────────────────────────┐
│ Panel: Messages In / Topic (rate)            │               │
│ Bar chart or stepped area                    │               │
├─────────────────────────────────────────────────────────────┤
│ Panel: Messages Out / Consumer Group (rate)  │               │
│ Step area, per consumer group                │               │
├─────────────────────────────────────────────────────────────┤
│ Panel: Message Rate Gap (in - out)           │               │
│ Positive = lag growing; negative = catching up │             │
└─────────────────────────────────────────────────────────────┘
```

**Row 3: Consumer Group Health** (time-series + stat, 3 panels)

```
┌─────────────────────────────────────────────────────────────┐
│ Panel: Consumer Group Members                │ Stat: Last    │
│ Step graph, per consumer group               │ Rebalance    │
│                                              │ Duration     │
├─────────────────────────────────────────────────────────────┤
│ Panel: Rebalance Events / 24h                │               │
│ Bar chart, per consumer group                │               │
├─────────────────────────────────────────────────────────────┤
│ Panel: Partition Assignment                  │               │
│ Table showing which member owns which partition            │
└─────────────────────────────────────────────────────────────┘
```

**Row 4: Broker Health** (time-series, 4 panels)

```
┌─────────────────────────────────────────────────────────────┐
│ Panel: CPU Usage                    │ Panel: Memory Usage   │
├─────────────────────────────────────────────────────────────┤
│ Panel: Disk Usage by Partition       │ Panel: Network I/O   │
└─────────────────────────────────────────────────────────────┘
```

**Row 5: Catch-Up Projection** (time-series, 1 panel)

```
┌─────────────────────────────────────────────────────────────┐
│ Panel: Estimated Catch-Up Time                              │
│ For each lagging consumer group, compute:                   │
│   predict_linear(kafka_consumer_lag[5m], 3600, $__interval) │
│ to estimate when lag reaches zero.                          │
│ Threshold line at 1h (warning) and 6h (critical).           │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Key PromQL Queries

**Current lag per consumer group**:
```promql
max by (topic, group) (
  redpanda_kafka_consumer_lag
)
```

**Lag per partition (stacked)**:
```promql
sum by (topic, partition, group) (
  redpanda_kafka_consumer_lag
)
```

**Lag change rate (lag/s)**:
```promql
deriv(redpanda_kafka_consumer_lag[5m])
```

**Message rate gap (in - out)**:
```promql
# Messages in per second
sum(rate(redpanda_kafka_partition_offset[1m])) by (topic)
-
# Messages consumed per second
sum(rate(redpanda_kafka_consumer_offset[1m])) by (topic, group)
```

**Rebalances per 24h**:
```promql
increase(redpanda_kafka_consumer_group_rebalance_count[24h])
```

**Estimated catch-up time (seconds)**:
```promql
(
  redpanda_kafka_consumer_lag
  /
  clamp_min(
    deriv(redpanda_kafka_consumer_offset[5m]),
    0.001
  )
)
```
Note: this produces infinity/NaN when consumption has stalled (deriv = 0). The Grafana panel should show a stat like "stalled" or ">24h" for those cases.

### 4.3 Dashboard Variables

| Variable | Type | Values | Default |
|----------|------|--------|---------|
| `topic` | custom | `cc.events`, `patrol.events`, `system.events`, `all` | `all` |
| `consumer_group` | custom | `ck-consumer-cc`, `ck-consumer-patrol`, `all` | `all` |
| `time_range` | custom | `15m`, `1h`, `6h`, `24h`, `7d` | `1h` |

---

## 5. Alerting Rules

### 5.1 Critical Alerts

| Alert Rule | Condition | Severity | Response |
|------------|-----------|----------|----------|
| **Lag > 1,000 messages** | `max(redpanda_kafka_consumer_lag) > 1000` for 5m | critical | Check CK Kafka Engine consumer; verify CK is accepting writes |
| **Lag growing for > 15 min** | `deriv(redpanda_kafka_consumer_lag[15m]) > 0` for 5m | critical | Lag is not stabilizing; CK Kafka Engine may be stuck or CK is slow |
| **Consumer group has 0 members** | `redpanda_kafka_consumer_group_members == 0` for 1m | critical | CK Kafka Engine consumer has crashed. No data is being consumed at all. |
| **Lag > 50% of retention** | `lag_seconds / retention_seconds > 0.5` | critical | Risk of data loss: unconsumed messages will expire before consumption resumes |

### 5.2 Warning Alerts

| Alert Rule | Condition | Severity | Response |
|------------|-----------|----------|----------|
| **Lag > 100 messages** | `max(redpanda_kafka_consumer_lag) > 100` for 5m | warning | Investigate: CK slowdown or burst of messages |
| **Rebalance > 3 / 24h** | `increase(redpanda_kafka_consumer_group_rebalance_count[24h]) > 3` | warning | Unstable consumer group; check CK Kafka Engine configuration (`kafka_num_consumers`) and CK health |
| **Consumption stalled > 5 min** | `deriv(redpanda_kafka_consumer_offset[5m]) == 0` for 5m | warning | Consumer is alive (member count > 0) but not processing; may be stuck on a poison message |
| **Disk usage > 80%** | `redpanda_disk_usage_bytes / redpanda_disk_capacity_bytes > 0.8` | warning | Redpanda disk filling; may stop accepting writes if limit reached |

### 5.3 Alertmanager Configuration

```yaml
# alertmanager.yml (relevant kafka-lag rules)
groups:
  - name: kafka_consumer_lag
    rules:
      - alert: KafkaConsumerLagCritical
        expr: max(redpanda_kafka_consumer_lag) > 1000
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Kafka consumer lag > 1000 messages"
          description: >
            Consumer group {{ $labels.group }} on topic {{ $labels.topic }}
            partition {{ $labels.partition }} has lag of {{ $value }} messages.

      - alert: KafkaConsumerLagGrowing
        expr: deriv(redpanda_kafka_consumer_lag[15m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Kafka consumer lag is growing"
          description: >
            Lag for {{ $labels.group }}/{{ $labels.topic }} is increasing at
            {{ $value | humanize }} msgs/s for the last 15 minutes.

      - alert: KafkaConsumerGroupEmpty
        expr: redpanda_kafka_consumer_group_members == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Consumer group has no members"
          description: >
            Consumer group {{ $labels.group }} has 0 members.
            No data being consumed from Kafka.

      - alert: KafkaConsumerLagWarning
        expr: max(redpanda_kafka_consumer_lag) > 100
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Kafka consumer lag > 100 messages"
          description: >
            Consumer group {{ $labels.group }} on topic {{ $labels.topic }}
            has lag of {{ $value }} messages.

      - alert: KafkaConsumerStalled
        expr: deriv(redpanda_kafka_consumer_offset[5m]) == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Kafka consumer stalled"
          description: >
            Consumer group {{ $labels.group }} on topic {{ $labels.topic }}
            has committed offset unchanged for 5 minutes.
            Consumer may be stuck on a poison message.

      - alert: KafkaRebalanceFrequent
        expr: increase(redpanda_kafka_consumer_group_rebalance_count[24h]) > 3
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Frequent consumer group rebalances"
          description: >
            Consumer group {{ $labels.group }} has rebalanced
            {{ $value }} times in the last 24h.
```

### 5.4 Feishu Notification Routing

Alerts route to the infra ops Feishu group (same alerting channel used by patrol).

| Severity | Feishu Group | Action |
|----------|--------------|--------|
| critical | `alert_infra` | Notify immediately with @all |
| warning | `alert_infra` | Notify without @all, auto-resolve within 24h |

---

## 6. Consumer Group: ClickHouse Kafka Engine

### 6.1 Known Behavior

ClickHouse Kafka Engine tables are **internal consumers** -- they are not standard Kafka consumer group clients. Key behaviors to understand for lag monitoring:

1. **Commit behavior**: CK commits offsets periodically (controlled by `kafka_commit_period_ms`, default 5000ms). This means the committed offset in Kafka lags behind the actual consumed position by up to 5 seconds.
2. **Num consumers**: `kafka_num_consumers` setting controls parallelism. For `cc.events` with 3 partitions, `kafka_num_consumers = 3` means 3 concurrent consumers, each assigned one partition. Lag should be balanced across partitions.
3. **Restart behavior**: On CK restart, each consumer resumes from the last committed offset. If retention has expired beyond the committed offset, messages are lost (the consumer skips to the earliest available offset).
4. **Error handling**: The Kafka Engine logs errors to CK's `system.errors` table. Messages that fail to parse are silently skipped (not retried).

### 6.2 CC Events Consumer

| Setting | Value | Rationale |
|---------|-------|-----------|
| Consumer group ID | `ck-consumer-cc` | Identifies this consumer in metrics |
| `kafka_num_consumers` | 3 | One per partition, max parallelism |
| `kafka_commit_period_ms` | 5000 | Commit every 5s for fresh lag metrics |
| `kafka_max_block_size` | 65536 | Max messages per batch insert |
| `kafka_skip_broken_messages` | 100 | Allow skipping up to 100 consecutive broken messages |
| `kafka_handle_error_mode` | `stream` | Route parse errors to a separate table instead of silent skip |

### 6.3 Patrol Events Consumer

| Setting | Value | Rationale |
|---------|-------|-----------|
| Consumer group ID | `ck-consumer-patrol` | Separate group from cc events |
| `kafka_num_consumers` | 1 | Only 1 partition for patrol events |
| `kafka_commit_period_ms` | 5000 | Standard 5s commit |
| `kafka_max_block_size` | 65536 | Standard batch size |

### 6.4 Error Tables for Parse Failures

To avoid silent data loss when Kafka messages fail to parse, add an error-handling table:

```sql
CREATE TABLE cc.kafka_parse_errors (
    event_time     DateTime64(3),
    topic          String,
    partition      Int32,
    offset         Int64,
    raw_message    String,
    error          String
) ENGINE = MergeTree
ORDER BY (event_time)
TTL event_time + INTERVAL 7 DAY;

-- Modified kafka_queue table with error handling
CREATE TABLE cc.kafka_queue (
    event_time      DateTime64(3),
    source          LowCardinality(String),
    event_type      LowCardinality(String),
    -- ... all other columns ...
    _error          String        -- captured parse error
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'host.orb.internal:9092',
    kafka_topic_list = 'cc.events',
    kafka_group_name = 'ck-consumer-cc',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3,
    kafka_handle_error_mode = 'stream';

-- Materialized view for error rows only
CREATE MATERIALIZED VIEW cc.kafka_errors_to_log TO cc.kafka_parse_errors AS
SELECT
    now() AS event_time,
    _topic AS topic,
    _partition AS partition,
    _offset AS offset,
    _raw_message AS raw_message,
    _error AS error
FROM cc.kafka_queue
WHERE _error != '';
```

This ensures parse failures are logged and visible, rather than silently skipped.

---

## 7. Rebalance Event Tracking

### 7.1 Why Track Rebalances

Consumer group rebalances occur when:
- A consumer joins or leaves the group (CK restart, scale-up/down)
- A partition leader changes (broker failure)
- A consumer fails to heartbeat (network issue, GC pause, CK overload)

Frequent rebalances are harmful because:
- **Stop-the-world**: during a rebalance, all consumers in the group pause processing (stop-consumer-join protocol).
- **Amplified lag**: each rebalance adds 5-30 seconds of zero consumption, allowing lag to accumulate.
- **Unstable assignment**: if rebalances happen faster than the cooldown period, the group enters a rebalance storm and never stabilizes.

### 7.2 Monitoring Rebalances

Redpanda exposes `redpanda_kafka_consumer_group_rebalance_count` (cumulative counter). To detect storms:

```promql
# Detect rebalance storm: rebalance interval < 5 minutes
(
  increase(redpanda_kafka_consumer_group_rebalance_count[30m])
  /
  30
) * 60 > 0.2
# Interpretation: more than 0.2 rebalances per minute = more than 1 per 5 minutes
```

### 7.3 Rebalance Event Schema for ClickHouse

To retain historical rebalance events (useful for post-mortem analysis), produce a structured event to `patrol.events` or a new `system.events` topic when a rebalance is detected:

```json
{
  "schema_version": "1.0",
  "source": "kafka-monitor",
  "event_type": "consumer_group_rebalance",
  "event_time": "2026-05-23T17:00:00.000Z",
  "producer": {
    "host": "kyb-infra-boss",
    "instance": "prometheus-alertmanager"
  },
  "payload": {
    "consumer_group": "ck-consumer-cc",
    "topic": "cc.events",
    "rebalance_count_24h": 5,
    "trigger": "rebalance_storm_detected",
    "member_count_before": 3,
    "member_count_after": 2,
    "lag_before": 50,
    "lag_after": 150
  }
}
```

This event is produced by a lightweight monitor script (see Section 9) that watches the Prometheus rebalance metric and publishes when the 24h rebalance count exceeds the warning threshold.

---

## 8. Catch-Up Time Prediction

### 8.1 Problem

"Lag is 500 messages" does not tell an operator whether the situation is urgent. 500 messages at 10 msgs/s is 50 seconds to catch up (fine). 500 messages at 0.1 msgs/s is 83 minutes (bad).

### 8.2 Solution

Compute estimated catch-up time from the rate of change of the consumer offset:

**Formula**:
```
catch_up_seconds = lag / consumption_rate
consumption_rate = deriv(consumer_offset[5m])   // messages per second
clamp_min(consumption_rate, 0.001)              // avoid division by zero
```

**In PromQL**:
```promql
(
  redpanda_kafka_consumer_lag
  /
  clamp_min(
    deriv(redpanda_kafka_consumer_offset[5m]),
    0.001
  )
)
```

**Grafana display**:
- If `catch_up_seconds < 60`: show "Catching up (X s remaining)", color green
- If `catch_up_seconds < 3600`: show "Catching up (X min remaining)", color yellow
- If `catch_up_seconds >= 3600`: show "Catching up (X h remaining)", color orange
- If `consumption_rate == 0`: show "STALLED - no consumption", color red
- If `lag == 0`: show "CAUGHT UP", color green

### 8.3 Alert Integration

The catch-up time feeds into alert severity escalation:

```
Lag > 100 messages AND catch_up > 1h  → warning (slow consumer)
Lag > 1000 messages AND catch_up > 1h → critical (very slow consumer)
Lag > 100 messages AND catch_up < 5m  → no alert (just a burst that will clear quickly)
```

This prevents alert fatigue from ephemeral lag bursts during normal operation.

---

## 9. Implementation Plan

### Phase 1: Prometheus Scrape + Dashboard (P0)

1. Add Redpanda target to Prometheus scrape config.
2. Verify `redpanda_kafka_consumer_lag` metric appears in Prometheus.
3. Create Grafana dashboard with Row 1 (Lag Overview) and Row 4 (Broker Health).
4. Test: manually produce messages and verify lag appears and decreases after CK consumes.

**Estimated effort**: 1 session (2h)

### Phase 2: Alerting (P1)

1. Deploy Alertmanager rules (Section 5).
2. Route critical alerts to Feishu `alert_infra` group.
3. Test: produce 1,001 messages to `cc.events` quickly, verify alert fires.
4. Tune thresholds if needed (100/1000 may be too sensitive at our volume of ~90 msgs/day).

**Note on volume**: At current scale (~900 events/day across all topics), lag of 100 messages represents ~2.7 hours of data. The critical threshold of 1,000 messages represents ~27 hours. These thresholds are appropriate for current volume.

**Estimated effort**: 1 session (1h)

### Phase 3: Rebalance Monitor (P1)

1. Deploy a lightweight monitor script that queries Prometheus rebalance metric and publishes to `system.events` or triggers a patrol event when rebalance frequency exceeds threshold.
2. Add rebalance event panel to Grafana dashboard (Row 3).

**Estimated effort**: 0.5 session

### Phase 4: Catch-Up Time Panel + Smart Alerts (P2)

1. Add catch-up time projection panel (Row 5).
2. Integrate catch-up time into alert severity logic.
3. Document alert response procedures.

**Estimated effort**: 0.5 session

---

## 10. Edge Cases and Failure Modes

| Scenario | Lag Behavior | Detection | Action |
|----------|-------------|-----------|--------|
| CK restarts | Lag spikes as messages accumulate during downtime | `lag > threshold` alert fires | Verify CK resumes and catches up. If retention exceeded, re-produce from sources. |
| CK Kafka Engine stuck (poison message) | Lag grows, committed offset frozen, member count > 0 | `consumption_stalled` alert | Check `cc.kafka_parse_errors` and `system.errors` in CK. Remove poison message from Kafka or increase `kafka_skip_broken_messages`. |
| Producer burst (e.g., cc-connect flood) | Lag spikes temporarily, then normalizes as consumer catches up | `lag > warning` may fire briefly | No action needed. Smart alert severity (catch-up time < 5m) prevents false positive. |
| Redpanda broker disk full | Broker stops accepting writes. Lag metrics become unavailable or inaccurate. | `disk_usage > 80%` warning alert | Increase disk or reduce retention. |
| Partition leader election | Brief lag spike during leader change (leader election takes ~1-3s) | May trigger transient alert | Tolerate 30s of lag deviation before alerting (already handled by `for: 5m`). |
| CK fails to commit offset | Committed offset appears frozen even though CK has consumed data | `consumption_stalled` false positive | Differentiate: check CK `system.kafka_consumers` for actual consumed offset vs committed offset. |
| Multiple consumers in same group | Lag splits across consumers. Total lag equals sum of partition lags. | Normal | Dashboard should sum partition lags for total group lag. |

---

## 11. Operational Runbook

### 11.1 Lag Detected -- Quick Diagnosis

```bash
# 1. Check current lag from command line
rpk group describe ck-consumer-cc

# 2. Check CK Kafka Engine status
clickhouse-client --query "SELECT * FROM system.kafka_consumers WHERE group_name = 'ck-consumer-cc'"

# 3. Check CK for errors
clickhouse-client --query "SELECT * FROM cc.kafka_parse_errors ORDER BY event_time DESC LIMIT 10"

# 4. Check CK system.errors
clickhouse-client --query "SELECT * FROM system.errors WHERE message LIKE '%kafka%' ORDER BY last_error_time DESC LIMIT 10"

# 5. Verify CK is alive and querying
clickhouse-client --query "SELECT count() FROM cc.kafka_queue"
```

### 11.2 Force Consumer Reset

If the consumer is stuck on a poison message and skipping is insufficient:

```sql
-- Option A: Detach and recreate the materialized view (safe, no data loss)
DETACH TABLE cc.kafka_to_message_log;
ALTER TABLE cc.kafka_queue MODIFY SETTING kafka_skip_broken_messages = 10000;
ATTACH TABLE cc.kafka_to_message_log;

-- Option B: Reset consumer offset forward (skip all current messages)
ALTER TABLE cc.kafka_queue MODIFY SETTING kafka_reset_offset = 'latest';
-- Then set back to 'earliest' after catch-up
```

### 11.3 After CK Outage Recovery

```bash
# 1. Verify CK is accepting connections
pg_isready -h host.orb.internal -p 9000  # ClickHouse port, not PG

# 2. Check consumer resumed
rpk group describe ck-consumer-cc

# 3. Monitor lag decreasing in Grafana
# 4. If lag > retention window, check for data loss:
clickhouse-client --query "
  SELECT min(event_time), max(event_time), count()
  FROM cc.message_log
  WHERE event_time > now() - INTERVAL 1 DAY
"
```

---

## 12. Future Considerations

### 12.1 Kafka Lag as a Top-Level SLO

Once the system stabilizes, define consumer lag SLOs:

| SLO | Target | Measurement |
|-----|--------|-------------|
| Lag < 100 messages (all topics) | 99.9% over 30d | `max(redpanda_kafka_consumer_lag) < 100` |
| Catch-up time < 5 min after CK restart | 100% | Time from CK restart to lag = 0 |
| Rebalances < 1 per week per group | 100% | `increase(redpanda_kafka_consumer_group_rebalance_count[30d]) < 4` |

### 12.2 Auto-Remediation

For critical lag scenarios (CK consumer stalled, lag > retention danger), an auto-remediation script could:

1. Detect stalled CK consumer via Prometheus API.
2. Restart ClickHouse container (`docker restart kyb-infra-clickhouse`).
3. Wait 30s, verify consumer resumed.
4. Notify Feishu with action taken.

This is a P3 item -- at current volume, manual recovery is acceptable.

### 12.3 Cross-Cluster Lag View

If Kafka expands to multiple clusters, the dashboard should have a cluster selector variable, and lag queries should join on the `cluster` label.

---

## References

- Kafka message bus design: `docs/infra/reviews/kafka-message-bus.md`
- Observability design overview: `docs/infra/observability-design.md`
- Redpanda metrics reference: https://docs.redpanda.com/current/reference/metrics/
- ClickHouse Kafka Engine docs: https://clickhouse.com/docs/en/engines/table-engines/integrations/kafka
- PromQL deriv() function: https://prometheus.io/docs/prometheus/latest/querying/functions/#deriv
