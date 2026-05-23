---
decision: 稍后做
---

# HTTP Hook Interception for cc-connect

**Date**: 2026-05-23
**Scope**: Dedicated webhook receiver that intercepts cc-connect native hook HTTP POSTs, enriches events, and writes to ClickHouse. Covers receiver design, enrichment pipeline, CK schema, deployment, and comparison with existing nginx-adapter and Kafka-pipeline approaches.

---

## 1. Motivation

### Problem

cc-connect v1.3.2+ native hooks can POST to a webhook URL, but existing approaches leave gaps:

| Approach | Status | Gap |
|----------|--------|-----|
| **Nginx adapter** (`cc-hooks-direct-ck.md`) | Proven, ~5 LOC | Thin URL rewrite only -- no enrichment, no validation, no pipeline health observability |
| **Kafka pipeline** (`hooks-kafka.md`) | Designed, not deployed | Adds Kafka REST Proxy dependency; 7d buffer is overkill at ~300 events/day |
| **Vector pipeline** (`bridge-ck-ingestion.md`) | Designed, not deployed | Parses Go slog key=value lines from stdout, not native hook JSON; regex parsing is brittle |

All three lack a **webhook receiver** with:
- Event enrichment (hostname, container_id, environment tags)
- Payload validation and schema normalization
- Pipeline health metrics (requests/sec, errors, latency percentiles)
- Built-in batching with backpressure for CK writes
- A health endpoint for patrol integration

### Solution

A lightweight **cc-hook-receiver** HTTP service that:

1. Receives all cc-connect hook POSTs on a single endpoint (`/hook`)
2. Validates JSON payload and enriches with metadata
3. Batch-writes to ClickHouse with configurable flush interval and backpressure
4. Exposes `/health` (for patrol/container health checks) and `/metrics` (for Prometheus)

This fills the observability gap that neither the nginx adapter nor the Kafka pipeline addresses: **visibility into the hook pipeline itself**.

---

## 2. Architecture

```
cc-connect (v1.3.2+)
    │  native hook fires on event
    │  HTTP POST JSON -> http://cc-hook-receiver:8430/hook
    │  3 retries, 5s timeout, exponential backoff
    ▼
┌─────────────────────────────────┐
│  cc-hook-receiver               │
│  (single Go binary, ~8 MB)      │
│                                 │
│  POST /hook                     │
│    → parse JSON envelope        │
│    → validate required fields   │
│    → enrich (hostname, env, ts) │
│    → push to batch buffer       │
│    → return 200 OK              │
│       (non-blocking, <5ms)      │
│                                 │
│  GET /health                    │
│    → 200 OK {"status":"ok"}     │
│                                 │
│  GET /metrics                   │
│    → Prometheus text format     │
└──────────┬──────────────────────┘
           │ batched INSERT ... FORMAT JSONEachRow
           │ flush: every 1s OR 20 events (whichever first)
           ▼
┌─────────────────────────────────┐
│  ClickHouse                     │
│  (host.orb.internal:8123)       │
│                                 │
│  cc.hook_events (MergeTree)     │
│  cc.hook_events_mv (MV for     │
│    enrichment)                  │
└─────────────────────────────────┘
```

### Key Design Principle: Non-Blocking Receive Path

cc-connect's hook retry budget (3 attempts, 5s timeout, exponential backoff ~7s total) is finite. The receiver MUST return 200 OK within 50ms for 99% of requests to avoid exhausting cc-connect's retry budget.

This means:
- **Validation and enrichment** must complete in <5ms (no IO)
- **CK write** is asynchronous -- the event is pushed to a channel buffer and batch-inserted later
- **200 OK** is returned before CK ack

If the CK write eventually fails, the event is lost (fail-open, matching the Claude hooks pattern).

---

## 3. cc-connect Hooks Configuration

cc-connect reads hooks config from a YAML file (or TOML, depending on version). The receiver URL points to `cc-hook-receiver:8430/hook`.

```yaml
# /etc/cc-connect/hooks.yaml
hooks:
  enabled: true
  backend: webhook
  webhook:
    url: "http://cc-hook-receiver:8430/hook"
    method: POST
    retry:
      max_attempts: 3
      backoff: exponential
      initial_interval: 1s
    timeout: 5s
  events:
    - message.received
    - response.complete
    - session.timeout
    - session.crashed
    - session.resumed
    - permission.requested
```

All 6 native events are enabled from day one. The receiver handles event-type-specific enrichment internally.

---

## 4. Receiver Design

### 4.1 Request Handling Flow

```
POST /hook
  │
  1. Parse body (limit 1MB)
  │
  2. Validate:
     - valid JSON
     - "event" field present (non-empty string)
     - "timestamp" field present (valid RFC3339)
     - "data" field present (object)
  │
  3. Enrich:
     - add receiver_hostname
     - add receiver_version
     - normalize event_time to DateTime64(3)
     - extract trace_id from headers if present
  │
  4. Push to batch channel (buffered, 1024 capacity)
  │
  5. Return 200 OK {"accepted":true}
  │
  [async] Batch worker:
     - collects events from channel
     - flushes every 1s OR 20 events (configurable)
     - builds INSERT query
     - POSTs to CK HTTP interface
     - on failure: log error + increment error counter
```

### 4.2 Batch Insert Strategy

| Parameter | Default | Rationale |
|-----------|---------|-----------|
| Flush interval | 1s | Low latency while batching |
| Max batch size | 20 events | Keeps POST body under ~50 KB |
| Buffer capacity | 1024 events | ~3s of buffer at peak rate (300/s theoretical ceiling) |
| CK timeout | 3s | Fail fast if CK is down |
| Retry on CK failure | 1 retry, no backoff | Fail-open after one retry |

At current volume (~300 events/day = ~1 event/5min), batches are effectively single-event inserts. Batching is prepared for future scale.

### 4.3 Enrichment

Every event gets these fields added before CK insert:

```json
{
  "receiver_hostname": "kyb-infra-boss",
  "receiver_container": "cc-hook-receiver",
  "receiver_version": "1.0.0",
  "ingested_at": "2026-05-23T16:38:00.654Z"
}
```

No PII is added. Enrichment is purely operational metadata for pipeline debugging and cross-referencing with other log sources.

### 4.4 Validation Rules

| Check | Action on Failure |
|-------|------------------|
| Body is valid JSON | Return 400, log warning |
| `event` field is non-empty string | Return 400, log warning |
| `timestamp` is valid RFC3339 | Set to receiver's `now()` |
| `data` is present and is object | Set to `{}` |
| Payload > 1MB | Return 413, increment error counter |

The receiver is lenient -- it accepts malformed events rather than dropping them. The `raw_payload` column preserves the original body for later analysis even when parsing fails.

### 4.5 Error Handling

| Scenario | HTTP Response | Event Stored? | CK Write Attempted? |
|----------|--------------|---------------|---------------------|
| Valid event | 200 OK | Yes | Yes |
| Invalid JSON body | 400 Bad Request | No | No |
| Missing `event` field | 400 Bad Request | No | No |
| Payload too large | 413 Payload Too Large | No | No |
| CK write fails (first attempt) | 200 OK (already returned) | No | Retried once |
| CK write fails (retry too) | 200 OK (already returned) | No | Dropped, increment ck_write_errors |

### 4.6 Health Endpoint

```json
GET /health
200 OK
{
  "status": "ok",
  "uptime_sec": 86400,
  "events_received": 12345,
  "events_written": 12340,
  "write_errors": 5,
  "buffer_usage_pct": 0.1,
  "last_event_sec": 2
}
```

This endpoint integrates with:
- Docker health check (`HEALTHCHECK --interval=30s CMD ...`)
- Patrol 5-minute check (`5min-patrol-guide.md`)
- cc-hook-receiver's own monitoring

### 4.7 Metrics Endpoint

Prometheus metrics exported at `GET /metrics`:

```prometheus
# HELP cc_hook_events_received Total events received
# TYPE cc_hook_events_received counter
cc_hook_events_received{event_type="message.received"} 42
cc_hook_events_received{event_type="response.complete"} 41
cc_hook_events_received{event_type="session.timeout"} 1
cc_hook_events_received{event_type="session.crashed"} 0
cc_hook_events_received{event_type="session.resumed"} 0
cc_hook_events_received{event_type="permission.requested"} 3

# HELP cc_hook_write_errors Total CK write errors
# TYPE cc_hook_write_errors counter
cc_hook_write_errors 0

# HELP cc_hook_buffer_size Current batch buffer size
# TYPE cc_hook_buffer_size gauge
cc_hook_buffer_size 0

# HELP cc_hook_duration_ms Request duration histogram
# TYPE cc_hook_duration_ms histogram
cc_hook_duration_ms_bucket{le="1"} 100
cc_hook_duration_ms_bucket{le="5"} 150
cc_hook_duration_ms_bucket{le="25"} 153
cc_hook_duration_ms_bucket{le="+Inf"} 153
cc_hook_duration_ms_sum 245
cc_hook_duration_ms_count 153
```

Metrics feed into Grafana dashboards for pipeline health monitoring.

---

## 5. ClickHouse Schema

### 5.1 Unified `cc.hook_events` Table

Reuses the same table schema from `cc-hooks-direct-ck.md` for consistency. The receiver writes the same structure that the nginx adapter would produce.

```sql
CREATE TABLE IF NOT EXISTS cc.hook_events (
    -- Event metadata (from envelope top-level + enrichment)
    event_time      DateTime64(3) DEFAULT now64(),
    event_type      LowCardinality(String),
    trace_id        String DEFAULT '',

    -- Core message fields (from data.*, populated per event type)
    msg_id          String DEFAULT '',
    session         String DEFAULT '',
    chat_id         String DEFAULT '',
    sender_id       String DEFAULT '',
    content_len     UInt32 DEFAULT 0,
    has_images      UInt8 DEFAULT 0,
    has_audio       UInt8 DEFAULT 0,
    has_files       UInt8 DEFAULT 0,

    -- Response fields (from response.complete data)
    response_len    UInt32 DEFAULT 0,
    turn_duration   Float64 DEFAULT 0,
    input_tokens    UInt32 DEFAULT 0,
    output_tokens   UInt32 DEFAULT 0,
    tools_used      UInt8 DEFAULT 0,

    -- Session lifecycle fields
    session_reason  LowCardinality(String) DEFAULT '',
    exit_code       Nullable(Int32),

    -- Permission fields
    permission_request_id String DEFAULT '',
    permission_decision  LowCardinality(String) DEFAULT '',

    -- Raw JSON payload for any unmapped fields (schema drift safety)
    raw_payload     String CODEC(ZSTD(3)) DEFAULT '',

    -- Receiver enrichment
    receiver_hostname  LowCardinality(String) DEFAULT '',
    receiver_version   LowCardinality(String) DEFAULT '',

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now(),
    _ck_instance    LowCardinality(String) DEFAULT 'kyb-infra-clickhouse',

    INDEX idx_raw_payload raw_payload TYPE tokenbf_v1(3072) GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY (toDate(event_time), event_type, msg_id)
TTL toDate(event_time) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

Changes from the `cc-hooks-direct-ck.md` schema:
- Added `receiver_hostname` and `receiver_version` columns for pipeline provenance
- All other columns match the existing schema (compatible with nginx adapter data)

### 5.2 Materialized View for Enrichment (Optional)

If the receiver is not deployed (falling back to nginx adapter), a materialized view adds enrichment at CK ingestion time:

```sql
CREATE MATERIALIZED VIEW cc.hook_enrichment TO cc.hook_events AS
SELECT
    *,
    hostname() AS receiver_hostname,
    '' AS receiver_version
FROM cc.hook_events_raw;
```

This allows the enrichment to happen in CK SQL when the receiver is absent, at the cost of slightly more complex schema. **Preferred approach**: enrichment in the receiver (less CK load, simpler schema).

---

## 6. Deployment

### 6.1 Container

```bash
docker run -d \
  --name cc-hook-receiver \
  --restart unless-stopped \
  --network kyb-net \
  -p 8430:8430 \
  -e CK_ENDPOINT=http://host.orb.internal:8123 \
  -e CK_DATABASE=cc \
  -e CK_TABLE=hook_events \
  -e LISTEN=:8430 \
  -e FLUSH_INTERVAL_MS=1000 \
  -e BATCH_SIZE=20 \
  cc-hook-receiver:latest
```

Or if built as part of the cc-connect container image:

```bash
docker exec -d kyb-infra-cc-connect cc-hook-receiver \
  --listen :8430 \
  --ck http://host.orb.internal:8123 \
  --db cc \
  --table hook_events
```

### 6.2 Docker Compose

```yaml
cc-hook-receiver:
  image: cc-hook-receiver:latest
  container_name: cc-hook-receiver
  restart: unless-stopped
  networks: [kyb-net]
  ports:
    - "8430:8430"
  environment:
    CK_ENDPOINT: "http://host.orb.internal:8123"
    CK_DATABASE: "cc"
    CK_TABLE: "hook_events"
    LISTEN: ":8430"
    FLUSH_INTERVAL_MS: "1000"
    BATCH_SIZE: "20"
  healthcheck:
    test: ["CMD", "curl", "-sf", "http://localhost:8430/health"]
    interval: 30s
    timeout: 5s
    retries: 3
    start_period: 5s
```

### 6.3 Build

```dockerfile
# Dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /build
COPY . .
RUN go build -o /cc-hook-receiver -ldflags="-s -w" ./cmd/receiver

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /cc-hook-receiver /usr/local/bin/
EXPOSE 8430
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://localhost:8430/health || exit 1
ENTRYPOINT ["cc-hook-receiver"]
```

Target binary size: ~8 MB (static Go binary).

### 6.4 Startup Order

1. ClickHouse starts (will accept writes on port 8123)
2. cc-hook-receiver starts
   - Connects to CK (optional -- starts even if CK is down)
   - Listens on :8430
   - Health endpoint reports `"status":"degraded"` if CK unreachable
3. cc-connect starts (or is reconfigured)
   - Loads hooks config
   - Begins POSTing events to `http://cc-hook-receiver:8430/hook`

If CK is down at receiver startup, the receiver still accepts events and buffers them (up to 1024). Once CK recovers, the batch worker drains the buffer.

---

## 7. Pipeline Observability

### 7.1 Grafana Dashboard: "Hook Pipeline Health"

| Panel | Query | Purpose |
|-------|-------|---------|
| Event rate | `count() / 60` by `event_type` | Events per minute, per type |
| Event latency | `quantile(0.95)(now() - event_time)` | Time from event creation to CK ingestion |
| Write errors | `cc_hook_write_errors` (counter) | CK write failures |
| Buffer depth | `cc_hook_buffer_size` (gauge) | Receiver buffer pressure |
| Request duration | Histogram `cc_hook_duration_ms` | Receiver HTTP latency |
| Last event time | `max(event_time)` | Pipeline silence detection |
| Session crashes | `count() WHERE event_type='session.crashed'` | Crash rate over time |

### 7.2 Alert Rules

| Rule | Level | Condition | Query |
|------|-------|-----------|-------|
| Pipeline silence | P2 | No events in 15 minutes | `SELECT count() FROM cc.hook_events WHERE event_time > now() - INTERVAL 15 MINUTE` -- if 0, alert |
| Write errors spike | P2 | >5 write errors in 5 minutes | `increase(cc_hook_write_errors[5m]) > 5` |
| High buffer pressure | P3 | Buffer > 80% capacity for >30s | `cc_hook_buffer_size > 819` (80% of 1024) |
| Session crashed | P1 | Any `session.crashed` event | `SELECT count() FROM cc.hook_events WHERE event_type='session.crashed' AND event_time > now() - INTERVAL 1 MINUTE` |
| Crash loop | P1 | 3+ crashes in 5 min per session | `SELECT session, count() FROM cc.hook_events WHERE event_type='session.crashed' AND event_time > now() - INTERVAL 5 MINUTE GROUP BY session HAVING count() >= 3` |
| Slow response | P2 | turn_duration > 120s | `SELECT msg_id, turn_duration FROM cc.hook_events WHERE event_type='response.complete' AND turn_duration > 120 AND event_time > now() - INTERVAL 5 MINUTE` |

### 7.3 Patrol Integration

The 5-minute patrol (`5min-patrol-guide.md`) adds a check:

```bash
# Check hook receiver health
curl -sf http://localhost:8430/health || echo "WARN: cc-hook-receiver unhealthy"

# Check recent hook activity
clickhouse-client --host host.orb.internal \
  --query "SELECT count() FROM cc.hook_events WHERE event_time > now() - INTERVAL 15 MINUTE" \
  | grep -q '^[1-9]' || echo "WARN: no hook events in 15min"
```

---

## 8. Comparison with Existing Approaches

| Aspect | Nginx Adapter (cc-hooks-direct-ck) | Kafka Pipeline (hooks-kafka) | HTTP Hook Receiver (this design) |
|--------|-----------------------------------|-----------------------------|----------------------------------|
| **Infrastructure** | nginx:alpine (~23 MB) | Redpanda/kafka + REST Proxy | Single Go binary (~8 MB) |
| **Config LOC** | ~10 lines nginx.conf | ~50 lines Kafka config + CK DDL | ~30 lines YAML + receiver config |
| **Enrichment** | None | None (raw Kafka record) | hostname, version, normalized timestamp |
| **Validation** | None | None | JSON schema validation, field presence |
| **Pipeline observability** | None | Kafka consumer lag only | `/health`, `/metrics`, CK error counters |
| **Batching** | None (per-event) | Kafka batching (native) | Configurable: 1s / 20 events |
| **Data loss on CK down** | Yes (events lost) | No (Kafka buffer, 7d retention) | Yes (in-memory buffer only, 1024 events) |
| **Latency overhead** | ~0.5ms (nginx) | ~5-10ms (REST proxy + Kafka write) | ~1-5ms (validation + enrichment) |
| **Fail-open** | Yes (nginx returns 502, cc-connect retries) | Yes (REST proxy down = event lost) | Yes (200 returned before CK write) |
| **Deployment complexity** | Low (just nginx config) | Medium (Kafka infra + topic setup) | Low (single binary or container) |
| **Setup time** | ~15 min | ~60 min | ~20 min |

### When to Use Each

| Scenario | Recommended Approach |
|----------|---------------------|
| **Minimal setup, enrichment needed** | HTTP Hook Receiver |
| **Minimal setup, no enrichment needed** | Nginx Adapter |
| **CK downtime tolerance critical** | Kafka Pipeline |
| **Need pipeline health observability** | HTTP Hook Receiver |
| **Already running Kafka/Redpanda** | Kafka Pipeline (reuse existing infra) |
| **Want Prometheus metrics on hooks** | HTTP Hook Receiver |
| **Resource-constrained host** | Nginx Adapter (alpine, 23 MB) |

---

## 9. Implementation Plan

### Phase 1: Receiver Core (Day 1)

- [ ] Go HTTP server with `/hook`, `/health`, `/metrics` endpoints
- [ ] JSON validation and enrichment
- [ ] Batch buffer with configurable flush interval and batch size
- [ ] CK HTTP writer with retry
- [ ] Dockerfile, HEALTHCHECK
- [ ] Manual end-to-end test: POST mock event, verify in CK

### Phase 2: Integration (Day 1-2)

- [ ] Deploy cc-hook-receiver container
- [ ] Configure cc-connect hooks YAML to point at receiver
- [ ] Verify all 6 event types land in CK
- [ ] Add patrol check for receiver health
- [ ] Add Grafana dashboard panel for pipeline health

### Phase 3: Alerting (Day 2)

- [ ] Add Grafana alert rules (pipeline silence, crash events, slow responses)
- [ ] Add Prometheus metric recording rules for write errors
- [ ] Test fail-open: stop CK, verify cc-connect continues operating

### Phase 4: Hardening (Week 2)

- [ ] Add Prometheus alert rules for receiver resource usage (if needed)
- [ ] Consider adding disk buffer for CK downtime resilience (LevelDB or similar)
- [ ] Load test with simulated high event rate

---

## 10. Risks and Mitigations

### 1. Receiver Becomes a SPOF (Medium)

If the receiver crashes, cc-connect's hook retries exhaust in ~7s and events are lost.

**Mitigation**:
- Docker `--restart unless-stopped` recovers within seconds
- `/health` endpoint enables patrol detection and manual restart
- Consider dual-receiver deployment with Docker DNS round-robin for P0 reliability
- Fallback: cc-connect can be reconfigured to POST directly to the nginx adapter URL (the nginx adapter config is a 1-line change in the hooks YAML)

### 2. In-Memory Buffer on CK Downtime (Low)

The 1024-event in-memory buffer will overflow if CK is down for extended periods. At ~300 events/day, 1024 events = ~3.3 days of buffer. If CK is down for >3 days, events are lost.

**Mitigation**:
- Current volume: 1024 events = 3.3 days of buffer, more than enough
- If volume grows: increase buffer size, or switch to disk-backed buffer
- If CK downtime > 1 hour is a real concern: deploy the Kafka pipeline instead

### 3. Double-Write on CK Retry (Medium)

If CK write succeeds but CK response is lost (network blip), the receiver retries and duplicates the event.

**Mitigation**:
- CK accepts duplicate rows (no primary key constraint on `cc.hook_events`)
- Deduplication query: `SELECT msg_id, event_type, count() FROM cc.hook_events GROUP BY msg_id, event_type HAVING count() > 1`
- Periodic dedup job: `DELETE` or collapse with `argMax` in a materialized view
- At current volume (~300 events/day), duplicates are negligible (~1-2/year per blip)

### 4. Schema Drift from cc-connect Updates (Low)

New cc-connect versions may add new hook events or change payload format.

**Mitigation**:
- `raw_payload` column preserves the original JSON unchanged
- New fields can be extracted from `raw_payload` via a backfill query
- The receiver validates `event` and `timestamp` only -- all other fields flow through to `raw_payload`

---

## 11. Comparison: Interception vs. Direct vs. Kafka

### Why Interception (Receiver) Adds Value

The nginx adapter is mechanically simpler, but it offers zero insight into the hook pipeline itself:

| You want to know... | Nginx adapter tells you | Receiver tells you |
|---------------------|------------------------|--------------------|
| "Are hooks being sent?" | Check CK table (eventually) | `/metrics` event counter in real-time |
| "Is CK rejecting my data?" | Check CK logs | `cc_hook_write_errors` counter |
| "What's the end-to-end latency?" | Not measurable | `now() - event_time` per row |
| "Which host sent this event?" | Not recorded | `receiver_hostname` column |
| "Is the pipeline healthy right now?" | Check CK (eventually) | `/health` endpoint |

### Why Not Just Add Nginx Logging

Nginx can log request details to a file, but:
- Nginx logs are text files requiring a separate log shipper (Vector) to reach CK
- Nginx cannot enrich the request body (it only logs what it sees)
- Nginx cannot validate or transform the JSON payload
- Nginx has no built-in Prometheus metrics for POST request bodies

### Why Not Use Vector as the Receiver

Vector can act as an HTTP source + ClickHouse sink. This was considered:

| Dimension | Vector as HTTP receiver | Dedicated Go receiver |
|-----------|------------------------|----------------------|
| Image size | ~150 MB | ~8 MB |
| Config complexity | VRL transform for enrichment | Go code (compile-time correct) |
| Prometheus metrics | Built-in (Vector internal) | Event-type-specific counters |
| Resource usage | ~30 MB RSS | ~5 MB RSS |
| Startup time | ~5s (VRL compilation) | ~10ms |
| Buffer on CK down | Disk buffer (configurable) | In-memory only (1024 cap) |

**Decision: Go receiver for now.** At current scale (~300 events/day), Vector is overkill. The Go receiver is simpler, smaller, and provides event-type-specific metrics that Vector's generic HTTP source cannot. If volume grows 100x and batching/buffering needs exceed the Go receiver's capabilities, Vector is the migration path.

---

## 12. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Receiver language | Go | Static binary, no dependencies, fast startup, good HTTP/stdlib support |
| Deployment | Standalone container | Clean separation from cc-connect; independent lifecycle and restart policy |
| CK write | Async batch with channel buffer | Non-blocking receive path prevents cc-connect retry exhaustion |
| Enrichment | In receiver | Simpler than CK materialized view; portable across databases |
| Metrics format | Prometheus text | Standard, integrates with existing Prometheus/Grafana setup |
| Buffer on CK down | In-memory (1024 events) | Sufficient at current volume; disk buffer adds complexity without need |
| Fallback path | Nginx adapter (from cc-hooks-direct-ck) | Zero new code; drop-in replacement if receiver is broken |

---

## 13. References

- Existing direct-to-CK design: `docs/infra/reviews/cc-hooks-direct-ck.md`
- Existing Kafka pipeline design: `docs/infra/reviews/hooks-kafka.md`
- Existing Bridge observability design: `docs/infra/observability-design.md`
- Claude Hooks to CK handbook: `docs/infra/handbook/hooks-ck-pipeline.md`
- Proxy intercept design (MITM pattern): `docs/infra/reviews/proxy-intercept.md`
- 5-minute patrol guide: `docs/infra/5min-patrol-guide.md`
- ClickHouse HTTP interface: https://clickhouse.com/docs/en/interfaces/http

---

> **Summary**: A dedicated HTTP hook receiver fills the observability gap left by the nginx adapter (no enrichment, no pipeline metrics) and the Kafka pipeline (overkill at current volume). With a ~8 MB Go binary, 30 LOC config, and ~20 min deployment, it provides event enrichment, pipeline health metrics, and CK batching with backpressure -- all while keeping the receive path non-blocking so cc-connect's finite retry budget is never exhausted.

> ／人◕ ‿‿ ◕人＼
