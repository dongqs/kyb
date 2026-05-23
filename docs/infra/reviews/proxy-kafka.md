---
decision: 不应该做
---

# Proxy Capture → Kafka → ClickHouse

**Design doc**: `docs/infra/reviews/proxy-kafka.md`
**Date**: 2026-05-23
**Scope**: Routing feishu-proxy WS frame captures through Kafka for buffered, replayable ingestion to ClickHouse
**Requires**: `proxy-intercept.md` (proxy design), `kafka-message-bus.md` (Kafka infra)

---

## 1. Motivation

The [proxy-intercept](proxy-intercept.md) design captures every WebSocket frame exchanged with feishu and writes JSON lines to stdout, collected by Vector and pushed directly to ClickHouse (`cc.ws_frames`). This works but inherits a critical weakness from the current direct-push pipeline: **no buffer between proxy and storage**.

| Gap | Impact |
|-----|--------|
| **CK downtime = data loss** | If Vector or CK is unavailable, frames are dropped. Proxy stdout has no retry mechanism. |
| **No replay from buffer** | Need to reprocess frames (e.g., schema migration in CK, debug a parser bug) requires re-capturing from live traffic. |
| **No backpressure isolation** | Slow CK inserts block Vector, which blocks proxy log collection. Proxy behavior is coupled to storage performance. |
| **Single point of routing** | All consumers must read from a single CK table. Adding a new consumer (e.g., a real-time monitor, a Feishu re-publisher) requires modifying the pipeline. |

Kafka between proxy and CK solves all four:

1. Proxy (or a shipper) publishes frames to a Kafka topic.
2. Kafka persists frames for configurable retention (default: 3 days).
3. ClickHouse consumes from Kafka via the Kafka Engine table — independent of producer speed.
4. Multiple consumers can read the same topic independently.

---

## 2. Architecture

### 2.1 Data Flow

```
Feishu (msg-frontier.feishu.cn)
    │ WSS
    ▼
feishu-proxy  (Go binary)
    │
    ├──► stdout: JSON lines (existing)
    │     │
    │     ▼
    │   Vector (existing pipeline, dual-write during migration)
    │     │
    │     └──► ClickHouse (cc.ws_frames)  ← fallback during migration
    │
    └──► Kafka topic: proxy.ws_frames
          │
          ├──► ClickHouse Kafka Engine → cc.ws_frames (primary path)
          │
          └──► Future consumers (replay, real-time monitor, alert)
```

### 2.2 Three Integration Approaches

#### Approach A: Proxy → stdout → Vector → Kafka (recommended for migration)

```
feishu-proxy ──► stdout ──► Vector ──► Kafka
```

No change to feishu-proxy. Vector reads proxy's JSON stdout (existing pipeline), and an additional `kafka` sink publishes to `proxy.ws_frames`. Vector's `docker_logs` source already captures proxy output (it shares a container with cc-connect).

**Pros**: Zero code change to proxy. Vector handles retries, batching, backpressure.
**Cons**: Extra hop through Vector adds latency (~5-50 ms). Vector's Kafka sink adds complexity to Vector config.

#### Approach B: Embedded Kafka producer in feishu-proxy (recommended long-term)

```
feishu-proxy ──► Kafka (direct, via Sarama/librdkafka)
```

feishu-proxy publishes each frame directly to Kafka using a Go Kafka client (Sarama or franz-go). Stdout logging becomes optional (debug mode only).

**Pros**: Low latency (no intermediate process). Fewer moving parts during normal operation. Direct backpressure from Kafka.
**Cons**: Proxy depends on Kafka availability. Adds ~3 MB to binary size (Go Kafka client). More complex error handling in the proxy.

#### Approach C: Proxy → stdout → kcat/filebeat shipper

```
feishu-proxy ──► stdout ──► kcat (tail + pipe) ──► Kafka
```

A minimal shell-based shipper: `tail -F` on proxy's stdout pipe, piping JSON lines through `kcat -P` to Kafka.

**Pros**: No Vector dependency. Dead simple to deploy. kcat is a single binary (~5 MB).
**Cons**: Shell-based, fragile on restart. No delivery guarantees if kcat crashes. No batching.

---

## 3. Recommendation

**Phase 1 (Migration)**: Approach A — Vector dual-writes to both CK (existing) and Kafka (new). Zero risk, no proxy code change. Run for 24 hours, verify row counts match.

**Phase 2 (Production)**: Approach B — Embed Kafka producer in feishu-proxy. Remove Vector from the critical path. Keep Vector only for the cc-connect log pipeline.

**Discard**: Approach C is too fragile for production. Use only for ad-hoc debugging.

---

## 4. Topic Design

### 4.1 Topic: `proxy.ws_frames`

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Partitions | 3 | Parallel consumption; partition by `conn_id` for per-connection ordering |
| Replication factor | 1 | Single broker (Redpanda dev mode) |
| Retention | 3 days | Enough for replay debugging; CK is the long-term store (90 days) |
| Cleanup policy | `delete` | Simple time-based |

### 4.2 Message Key

**Key**: `conn_id` (string) — ensures all frames from the same WS connection land in the same partition, preserving frame order.

### 4.3 Schema

Leverages the unified envelope from the [Kafka message bus](kafka-message-bus.md) design:

```json
{
  "schema_version": "1.0",
  "source": "feishu-proxy",
  "event_type": "ws_frame",
  "event_time": "2026-05-23T16:38:00.604123457Z",
  "producer": {
    "host": "kyb-boss",
    "instance": "kyb-infra-cc-connect",
    "proxy_version": "1.0.0"
  },
  "payload": {
    "conn_id": "conn_a1b2c3",
    "stream": "upstream",
    "direction": "recv",
    "opcode": "text",
    "frame_len": 1428,
    "frame_seq": 1,
    "payload_truncated": true,
    "payload_sha256": "abc123def456...",
    "msg_id": "om_xxxxxxxx"
  }
}
```

Key fields differ from the stdout JSON format (proxy-intercept.md §5.2) in one way: **payload is NOT included in the Kafka message by default**. Rationale:

- Kafka messages are persistent (retained for 3 days). Storing payloads in Kafka multiplies storage cost.
- Payloads are re-materializable from CK (90-day retention) or from the full-capture file dump if `--capture-dir` is enabled.
- If payload is needed for real-time consumers, add a separate `proxy.ws_frames_full` topic (1 partition, 12h retention) for full payloads.

If a consumer needs payloads, it reads from CK (historical) or subscribes to `proxy.ws_frames_full` (real-time).

### 4.4 Optional Topic: `proxy.ws_frames_full`

| Parameter | Value |
|-----------|-------|
| Partitions | 1 |
| Retention | 12 hours |
| Payload | Full (up to `--max-payload-log` config, default 4096 bytes) |

Only enabled when a real-time consumer needs frame payloads (e.g., a frame-inspector tool). Not part of the default pipeline.

---

## 5. ClickHouse Integration

Uses the same Kafka Engine pattern from `kafka-message-bus.md` §5.

### 5.1 Kafka Engine Table

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

    -- envelope fields
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

### 5.2 Materialized View to MergeTree

```sql
CREATE MATERIALIZED VIEW cc.ws_kafka_to_frames TO cc.ws_frames AS
SELECT
    event_time,
    conn_id,
    stream,
    direction AS dir,
    opcode,
    frame_len AS len,
    payload_truncated AS payload_truncated,
    payload_sha256,
    msg_id,
    frame_seq,
    producer_host AS proxy_hostname
FROM cc.ws_kafka;
```

### 5.3 Schema Alignment

The existing `cc.ws_frames` table (defined in `proxy-intercept.md` §6.2) has slightly different column names from the Kafka envelope:

| proxy-intercept column | Kafka payload field | MV mapping |
|---|---|---|
| `direction` | `direction` | direct (but aliased to `dir` in the MV) |
| `frame_len` | `frame_len` | direct (but aliased to `len` in the MV) |
| `payload_truncated` | `payload_truncated` | direct (note: UInt8 vs boolean) |
| `proxy_hostname` | `producer.host` | via MV |
| `conn_id` | `conn_id` | direct |

The MV reconciles these differences. **The existing `cc.ws_frames` table schema does not change.** The Kafka-backed pipeline writes to the same table, making it transparent to Grafana dashboards.

Note: `payload` and `payload_truncated` semantics are identical to the Vector path. Kafka messages omit the `payload` field by default (see §4.3).

---

## 6. Reliability Analysis

### 6.1 Failure Modes

| Failure | Effect | Recovery |
|---------|--------|----------|
| **Kafka broker down** | Proxy cannot publish. feishu-proxy blocks or drops frames depending on producer config. | **Approach A**: Vector buffers in memory (configurable). Proxy unaffected. **Approach B**: Configure producer with `queue.buffering.max.ms` and an in-memory ring buffer. Frames dropped if buffer full. |
| **CK down** | Kafka consumption stops; frames accumulate in `proxy.ws_frames` for up to 3 days. | No data loss. CK restarts, consumer resumes from committed offset. |
| **CK volume loss** | CK table empty. | Replay all frames from Kafka (3-day window) into CK. Partial recovery only (beyond 3 days, frames lost). |
| **Kafka volume loss** | Unconsumed frames lost. | CK retains previously consumed frames (90-day TTL). Only frames produced after the last consumer offset are lost. |
| **Proxy crashes** | No new frames captured. CC-connect fails open (bypass mode per proxy-intercept §4.3). | Proxy restarts (Docker restart policy). New Kafka producer with a fresh `client.id`. Frames during downtime lost. |

### 6.2 Data Guarantees

| Guarantee | Current (stdout→Vector→CK) | With Kafka (Approach B) |
|-----------|---------------------------|--------------------------|
| At-least-once | No (Vector delivers once, no retry on CK failure) | Yes (Kafka producer retries with `acks=all`; consumer commits offset after CK insert) |
| Exactly-once | N/A | Not needed (duplicate frames are detected by `conn_id + frame_seq` uniqueness) |
| Ordering within connection | Yes (Vector preserves log order) | Yes (partitioned by `conn_id`) |
| Latency (p99) | ~100ms (Vector batching) | ~10ms (direct Kafka produce) + ~100ms (CK consumer batch) |

### 6.3 Deduplication

Frames are naturally deduplicable: `(conn_id, frame_seq)` is unique per connection. If Kafka delivers a duplicate (rare with `acks=all` + `enable.idempotence=true`), CK's Kafka Engine may insert the row twice. Mitigation:

- **Option 1 (recommended)**: Accept duplicates. Add `REPLACING_MERGE_TREE` engine to `cc.ws_frames` with `(conn_id, frame_seq)` as the version column. Clean up at merge time.
- **Option 2**: Use a `ReplacingMergeTree` with `(conn_id, frame_seq)` as the sorting key and a version column.
- **Option 3 (simplest)**: Ignore — duplicates at this volume (~540 frames/day) are negligible. Deduplicate in queries with `SELECT DISTINCT`.

Recommendation: **Option 3 initially**. If duplicates become problematic, switch to `ReplacingMergeTree`.

### 6.4 Backpressure

```
Kafka produce succeeds ──► CK consumer reads at its own pace
                              │
                              ▼
                     CK is slow? Consumer pauses,
                     offsets not committed.
                     Frames buffer in Kafka.
```

The critical benefit: **proxy is never blocked by CK**. The Kafka buffer absorbs CK slowdowns automatically. The only backpressure proxy sees is from Kafka itself (which at this volume is effectively zero).

### 6.5 Fail-Open Behavior

**If Kafka is unreachable**, the feishu-proxy must not fail or block cc-connect's WS traffic.

Approach B handles this with a **circuit breaker** in the Kafka producer:

```go
// Pseudocode
type FramePublisher struct {
    producer  *kafka.Producer
    failures  int
    threshold int       // e.g., 5 consecutive failures
    state     string    // "open", "half-open", "closed"
}

func (p *FramePublisher) Publish(frame Frame) error {
    if p.state == "open" {
        // Kafka is down — drop frame, log warning
        log.Warn("Kafka unavailable, dropping frame", "frame_seq", frame.Seq)
        return nil  // never block
    }

    err := p.producer.Produce(frame)
    if err != nil {
        p.failures++
        if p.failures >= p.threshold {
            p.state = "open"
        }
        return err
    }

    p.failures = 0
    if p.state == "half-open" {
        p.state = "closed"
    }
    return nil
}

// Background goroutine: health check every 30s
// On success in "open" state: switch to "half-open"
```

The health check goroutine pings Kafka's metadata API every 30 seconds. If Kafka recovers, the circuit transitions: `open → half-open → closed`.

**During circuit-open state**, frames are silently dropped. This is acceptable because:
- The same frames are still forwarded to cc-connect (the relay function is independent of logging).
- If full-capture mode (`--capture-dir`) is enabled, frames are still written to disk.
- CK has historical data; a few minutes of dropped frames during a Kafka outage is tolerable.

---

## 7. Implementation: Approach B (Embedded Kafka Producer)

### 7.1 Changes to feishu-proxy

**New flag**:

```
--kafka-broker host.orb.internal:9092
    (default: empty = no Kafka, stdout-only mode)

--kafka-topic proxy.ws_frames
    (default: proxy.ws_frames)

--kafka-circuit-breaker 5
    (default: 5 consecutive failures before opening circuit)

--kafka-flush-timeout 5s
    (default: 5 seconds)

--kafka-batch-size 50
    (default: 50 frames per batch)
```

**Internal architecture**:

```
Frame capture (per WS frame)
    │
    ├──► stdout JSON line (existing)      ← always, for debugging
    │
    ├──► Kafka producer (async, batch)    ← new, if --kafka-broker set
    │     │
    │     ├──► Circuit breaker            ← prevents blocking
    │     │
    │     └──► In-memory ring buffer      ← 10,000 frames, LRU drop
    │
    └──► Capture file (if --capture-dir)  ← existing, full payloads
```

**Ring buffer for producer backpressure**:

If the Kafka producer's internal buffer is full (e.g., Kafka is slow), older frames are dropped from the ring buffer rather than blocking the proxy's main loop. The ring buffer is sized to hold ~10,000 frames (at ~200 bytes each ≈ 2 MB). Frame drops are logged with a rate-limited counter.

### 7.2 Go Dependencies

- **franz-go** (github.com/twmb/franz-go): Modern Go Kafka client, no cgo, actively maintained.
  - Size: ~3 MB added to binary.
  - Alternative: **Sarama** (github.com/IBM/sarama) — more widely used, but larger (~5 MB) and GPL-licensed.

Recommendation: **franz-go** for smaller binary size and cleaner async produce API.

### 7.3 Code Sketch

```go
import "github.com/twmb/franz-go/pkg/kgo"

type KafkaConfig struct {
    Brokers          []string
    Topic            string
    CircuitBreakerThreshold int
    FlushTimeout     time.Duration
    BatchSize        int
}

type KafkaPublisher struct {
    client   *kgo.Client
    topic    string
    breaker  *CircuitBreaker
    ringBuf  *RingBuffer
    dropped  atomic.Int64  // stat counter
}

func NewKafkaPublisher(cfg KafkaConfig) *KafkaPublisher {
    client, _ := kgo.NewClient(
        kgo.SeedBrokers(cfg.Brokers...),
        kgo.ProducerBatchCompression(kgo.Lz4Compression()),
        kgo.RequiredAcks(kgo.AllISRAcks()),
        kgo.DefaultProduceTopic(cfg.Topic),
    )
    return &KafkaPublisher{
        client:  client,
        topic:   cfg.Topic,
        breaker: NewCircuitBreaker(cfg.CircuitBreakerThreshold),
        ringBuf: NewRingBuffer(10000),
    }
}

func (p *KafkaPublisher) Publish(frame Frame) error {
    if !p.breaker.Allow() {
        // Circuit open — try ring buffer, then drop
        if !p.ringBuf.TryPush(frame) {
            p.dropped.Add(1)
        }
        return nil
    }
    // Produce async — non-blocking
    record := p.encode(frame)
    p.client.Produce(context.Background(), record, func(r *kgo.Record, err error) {
        if err != nil {
            p.breaker.Failure()
            log.Warn("kafka produce failed", "err", err, "frame_seq", frame.Seq)
        } else {
            p.breaker.Success()
        }
    })
    return nil
}
```

---

## 8. Dual-Write Migration (Phase 1)

### 8.1 Vector Kafka Sink

During Phase 1, Vector reads feishu-proxy's stdout and dual-writes to both CK (existing) and Kafka (new):

```toml
[sources.proxy_stdout]
type = "docker_logs"
include_containers = ["cc-connect"]
# Narrow to proxy frames: lines matching 'frame_seq'
# Use a transform to filter

[transforms.proxy_filter]
type = "filter"
inputs = ["proxy_stdout"]
condition = '''
  exists(.message) && contains(.message, "frame_seq")
'''

[transforms.proxy_parse]
type = "remap"
inputs = ["proxy_filter"]
source = '''
  parsed = parse_json!(.message)
  . = parsed
  .source = "feishu-proxy"
  .schema_version = "1.0"
  .event_type = "ws_frame"
  .producer.host = get_hostname!()
  .producer.instance = "kyb-infra-cc-connect"
'''

# Existing CK sink (unchanged)
[sinks.proxy_ck]
type = "clickhouse"
inputs = ["proxy_parse"]
endpoint = "http://clickhouse:8123"
database = "cc"
table = "ws_frames"

# New Kafka sink (dual-write)
[sinks.proxy_kafka]
type = "kafka"
inputs = ["proxy_parse"]
bootstrap_servers = "host.orb.internal:9092"
topic = "proxy.ws_frames"
encoding.codec = "json"

[sinks.proxy_kafka.batching]
max_events = 50
timeout_secs = 2
```

### 8.2 Verification

Run both pipelines for 24 hours. Verify:

```sql
-- Row count check
SELECT toDate(event_time) AS day, count() AS rows
FROM cc.ws_frames
WHERE event_time > now() - INTERVAL 1 DAY
GROUP BY day;

-- Count from Kafka consumer: use rpk topic consume
-- rpk topic consume proxy.ws_frames --num 1000 | wc -l
```

If counts match within 1%, switch Grafana to the Kafka-sourced data and remove the Vector CK sink.

---

## 9. Resource Estimation

### 9.1 Kafka Storage

| Item | Value |
|------|-------|
| Daily frames | ~540 |
| Kafka message size (no payload) | ~200 bytes |
| Daily Kafka volume | ~108 KB |
| 3-day retention | ~324 KB |
| With payload (full topic) | ~108 KB + ~50 KB/frame = ~27 MB/day |
| Full topic 12h retention | ~13.5 MB |

**Kafka storage is negligible.** Even with the full-payload topic, it's ~40 MB — insignificant for a single-broker Redpanda instance.

### 9.2 CK Storage

Unchanged from `proxy-intercept.md` §6.4: ~1.5 MB (90 days, truncated). The Kafka Engine table (`cc.ws_kafka`) adds a tiny buffer table (~100 KB) which is transient.

### 9.3 Binary Size

| Component | Size |
|-----------|------|
| feishu-proxy (current) | ~5 MB |
| feishu-proxy + franz-go | ~8 MB |
| feishu-proxy + full capture | ~8 MB + capture data |

The embedded Kafka producer adds ~3 MB to the binary. Acceptable.

---

## 10. Grafana Updates

No changes needed. The Kafka-backed pipeline writes to the same `cc.ws_frames` table. All existing panels (`proxy-intercept.md` §6.3) continue to work.

New panel:

| Panel | Query | Purpose |
|-------|-------|---------|
| Kafka consumer lag | `SELECT * FROM cc.ws_kafka` → use CK `system.kafka_consumers` or Redpanda metrics | Detect if CK consumer is falling behind |

---

## 11. Operational Notes

### 11.1 Kafka Partition Rebalancing

If a CK Kafka Engine consumer crashes and rejoins with a different consumer group member, partition rebalancing occurs. During rebalancing (typically < 1 second), no frames are consumed from the affected partitions. Frames continue to buffer in Kafka. At 540 frames/day, this is invisible.

### 11.2 Offset Reset Policy

Set `kafka_auto_offset_reset = 'earliest'` on the CK Kafka Engine table. If the consumer group loses its offset (e.g., fresh deployment), it starts from the earliest available message in the topic (up to 3 days). This ensures no data is missed on consumer restart.

### 11.3 Proxy Version in Schema

The `proxy_version` field in the envelope allows detecting schema changes across proxy versions. If the frame format changes, downstream consumers can branch on `proxy_version`.

---

## 12. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Integration approach (phase 1) | Vector dual-write | Zero risk, no proxy code change, reuses existing pipeline |
| Integration approach (phase 2) | Embedded Kafka producer (franz-go) | Lowest latency, fewest moving parts, circuit breaker for fail-open |
| Payload in Kafka message | Omitted by default; separate `proxy.ws_frames_full` topic | Reduces Kafka storage by ~250x; payloads available in CK or capture files |
| Partition key | `conn_id` | Preserves frame order within a connection |
| Retention | 3 days (Kafka), 90 days (CK) | Kafka: enough for replay debugging. CK: operational analysis. |
| Deduplication | Accept duplicates initially; ReplacingMergeTree if needed | Volume is too low for duplicates to matter |
| Circuit breaker | 5 consecutive failures → open; health check every 30s | Prevents proxy blocking when Kafka is down; auto-recovery |
| Go Kafka client | franz-go | Smaller binary (~3 MB), async API, no cgo |

---

## 13. Open Questions

| Question | Options | Decision Needed |
|----------|---------|-----------------|
| Ring buffer size for proxy Kafka producer | (a) 10,000 frames (~2 MB) (b) 100,000 frames (~20 MB) (c) No buffer, drop immediately | Depends on expected Kafka outage duration. 10k = ~18 hours of frames. |
| Health check interval for circuit breaker | (a) 30s (b) 60s (c) Exponential backoff (10s, 30s, 60s, 300s) | 30s is fine; no need to optimize. |
| Should full-payload topic be created eagerly? | (a) Yes, always (b) Only on demand (c) Never | Create only when a consumer needs it. No reason to pre-allocate. |
| `proxy.ws_frames` compaction policy | (a) `delete` (default) (b) `compact` (keep latest per key) (c) `compact,delete` | `delete` is fine — we never need to update a frame. |

---

## 14. Related Documents

- [proxy-intercept.md](proxy-intercept.md) — Proxy design (MITM, frame capture, replay system)
- [kafka-message-bus.md](kafka-message-bus.md) — Kafka event bus design (topics, schema, deployment)
- [bridge-ck-ingestion.md](../designs/bridge-ck-ingestion.md) — cc-connect message ingestion pipeline (prior art for Vector + CK)

---

> **Summary**: Adding Kafka between feishu-proxy and ClickHouse provides a buffer that absorbs CK downtime (no data loss), enables multi-consumer routing, and decouples proxy performance from storage performance. The dual-write migration (Vector simultaneously writes to CK and Kafka) eliminates deployment risk. Long-term, embedding a Kafka producer directly in feishu-proxy reduces latency and removes Vector from the critical path. Estimated Kafka storage cost: ~324 KB for 3 days of frames (truncated, no payload).

> /人◕ ‿‿ ◕人＼
