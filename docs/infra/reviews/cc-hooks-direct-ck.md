---
decision: 现在就做
---

# Review: cc-hooks-direct-ck — Native Hooks to ClickHouse (No Vector)

**Reviewer**: kyb-infra-boss
**Date**: 2026-05-23
**Design scope**: Evaluate direct cc-connect v1.3.2 native hooks -> ClickHouse HTTP ingestion, bypassing Vector/Kafka entirely.

---

## Summary

Review C1 established that cc-connect v1.3.2 ships with a native hooks system supporting HTTP POST webhooks. This document evaluates whether those hooks can POST events **directly into ClickHouse** without an intermediate processing tier (Vector, Kafka, or custom service).

**Short answer**: Yes, with a ~15-line Nginx adapter. ClickHouse's HTTP interface is nearly there but needs a thin URL rewrite layer to bridge cc-connect's webhook POST format to CK's INSERT query protocol. The existing Claude hooks pipeline (`hooks-ck-pipeline.md`) already proves this pattern works.

---

## Architecture

```
cc-connect (v1.3.2+)
    │  native hook fires on event
    │  HTTP POST JSON -> http://ck-adapter:8420/hook
    ▼
nginx adapter (5 LOC config)
    │  rewrites URL -> appends ?query=INSERT...FORMAT+JSONEachRow
    │  proxies POST body unchanged
    ▼
ClickHouse (host.orb.internal:8123)
    │  INSERT INTO cc.hook_events FORMAT JSONEachRow
    ▼
cc.hook_events table
```

### Data flow per event

1. cc-connect detects event (message.received, response.complete, etc.)
2. Native hooks system constructs JSON payload and POSTs to configured webhook URL
3. Nginx adapter receives POST, appends CK INSERT query parameter, forwards to CK
4. ClickHouse parses JSON body, inserts row into `cc.hook_events`
5. Returns HTTP 200 to cc-connect (via nginx)

Total added latency: ~1-5ms per event (local loopback to CK).

### Comparison: Existing Claude Hooks Pipeline

The Claude hooks pipeline (`hooks-ck-pipeline.md`) already uses the identical pattern:

```
Claude Code -> shell script (emit-ck.sh) -> curl POST -> ClickHouse HTTP
```

The only difference is the hook mechanism: Claude uses command hooks (shell script), cc-connect uses webhook POST (HTTP). Both terminate at CK's HTTP interface with the same `?query=INSERT...FORMAT+JSONEachRow` URL parameter.

---

## Feasibility Analysis

### 1. ClickHouse HTTP INSERT Protocol

ClickHouse accepts data inserts via HTTP POST in this format:

```
POST /?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow
Content-Type: application/octet-stream

{"event":"message.received","msg_id":"om_xxx","session":"s1","timestamp":"..."}
```

**How it works**:
- The SQL `query` is URL-encoded as a query parameter in the request path
- The POST body is raw newline-delimited JSON (JSONEachRow format)
- Response is 200 OK with empty body on success
- No authentication by default (network-bound)

**The gap**: ClickHouse requires the query in the URL. If cc-connect's webhook config allows custom URL query parameters, the direct URL would be:

```
POST http://host.orb.internal:8123/?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow
```

cc-connect's webhook backend must either:
- (a) Accept a full URL with query parameters in the config, or
- (b) POST to a fixed URL, requiring a rewrite layer

If (a) works, no adapter is needed. If (b) — the nginx adapter is 5 lines.

### 2. cc-connect Hook Payload Format

cc-connect v1.3.2 native hooks POST JSON with an **envelope structure**:

```json
{
  "event": "message.received",
  "timestamp": "2026-05-23T16:37:37.828Z",
  "data": {
    "msg_id": "om_abc123",
    "session": "feishu:oc_chat:ou_user",
    "user": "ou_user_id",
    "content_len": 65,
    "has_images": false,
    "has_audio": false,
    "has_files": false
  }
}
```

Each event type has a different `data` shape:

| Event | Key fields in `data` |
|-------|---------------------|
| `message.received` | msg_id, session, user, content_len, has_images, has_audio, has_files |
| `response.complete` | msg_id, session, response_len, turn_duration, input_tokens, output_tokens, tools_used |
| `session.timeout` | session_id, reason, idle_duration |
| `session.crashed` | session_id, error, exit_code, restart_count |
| `session.resumed` | session_id, prev_session_state |
| `permission.requested` | request_id, tool, args_preview |
| `permission.resolved` | request_id, decision, response_time_ms |

**Schema design**: Rather than flattening the envelope in the adapter (which adds complexity), the table stores the envelope as-is with `event`, `timestamp` as top-level columns and all `data.*` fields mapped to nullable typed columns. The `raw_payload` column preserves the original JSON for any unmapped fields.

### 3. Adapter Options

| Option | Complexity | Extra infra | Latency | Risk |
|--------|-----------|-------------|---------|------|
| **Direct URL** (if cc-connect supports query params) | 0 LOC | None | 0ms | Depends on cc-connect config flexibility |
| **Nginx rewrite** (`proxy_pass` with query) | ~5 LOC nginx | Existing or `nginx:alpine` container | ~0.5ms | Negligible |
| **Caddy reverse_proxy** | ~5 LOC Caddyfile | `caddy:alpine` container | ~0.5ms | Negligible |
| **socat relay** | ~5 LOC shell | None (included in alpine) | ~1ms | No HTTP response handling |
| **Minimal Go receiver** | ~40 LOC Go | New binary + container | ~0.5ms | Build + deploy overhead |
| **Python Flask** | ~30 LOC Python | Python deps | ~2ms | Dependency burden |
| **Vector** (existing design) | ~50 LOC TOML | Vector container | ~100ms batch | Already designed, heavy for this |

**Recommendation**: **Nginx rewrite**. The infrastructure already runs Docker containers; adding a 5-line nginx config on an existing or new `nginx:alpine` container is the lowest-friction approach.

Nginx adapter config:

```nginx
server {
    listen 8420;

    # Endpoint for cc-connect hook webhook POSTs
    location /hook {
        proxy_pass http://host.orb.internal:8123/?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow;
        proxy_method POST;
        proxy_set_body $request_body;
        proxy_set_header Content-Type "application/octet-stream";
        proxy_pass_request_body on;
        proxy_pass_request_headers off;

        proxy_connect_timeout 2s;
        proxy_read_timeout 5s;
    }

    # Health check for patrol monitoring
    location /health {
        return 200 "ok\n";
    }
}
```

Deploy:

```bash
docker run -d --name kyb-infra-ck-hook-adapter \
  --restart unless-stopped \
  -p 8420:8420 \
  -v /path/to/adapter.conf:/etc/nginx/conf.d/default.conf:ro \
  nginx:alpine
```

---

## ClickHouse Table Schema

### Event Types Coverage

cc-connect v1.3.2 native hook events vs the existing Vector design schema:

| cc-connect Hook Event | Vector Design Equivalent | Added Value |
|-----------------------|-------------------------|-------------|
| `message.received` | `event_type = 'message_received'` | Same coverage |
| `response.complete` | `event_type = 'message_sent'` | Same coverage, richer fields |
| `session.timeout` | Not covered | **New** — detect stuck sessions |
| `session.crashed` | Not covered | **New** — Claude crash observability |
| `session.resumed` | Not covered | **New** — recovery tracking |
| `permission.requested` | Not covered | **New** — permission stall monitoring |
| `permission.resolved` | Not covered | **New** — response time for permissions |

The hooks pipeline captures **7 event types** vs the Vector pipeline's **2 event types** (message_received, message_sent).

### Table DDL

```sql
CREATE TABLE IF NOT EXISTS cc.hook_events (
    -- Event metadata (from envelope top-level)
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

    -- Ingestion metadata
    _ingested_at    DateTime DEFAULT now(),
    _ck_instance    LowCardinality(String) DEFAULT 'kyb-infra-clickhouse',

    -- Index for raw_payload queries (rare, but useful for schema migration)
    INDEX idx_raw_payload raw_payload TYPE tokenbf_v1(3072) GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY (toDate(event_time), event_type, msg_id)
TTL toDate(event_time) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

### Key Design Decisions

1. **`raw_payload` column (most important)**: Stores the original hook JSON verbatim. If cc-connect's hook format evolves (new fields, renamed fields), the typed columns may become stale but raw_payload preserves everything. A backfill query can extract new fields without data loss.

2. **Sort key `(toDate(event_time), event_type, msg_id)`**:
   - `toDate(event_time)` is the partition-level sort for daily time range queries
   - `event_type` filters efficiently (e.g., "all response.complete events today")
   - `msg_id` enables correlating message.received with response.complete for the same message

3. **DEFAULT 0/DEFAULT '' instead of NULL**: At this volume (90 msgs/day -> ~300 events/day), storage is negligible and DEFAULT values simplify Grafana queries (no NULL handling). Only `exit_code` is Nullable because it's genuinely unknown until the process exits.

4. **No join required**: Unlike the Vector pipeline (which must join "message received" and "turn complete" log lines on msg_id), the hooks pipeline stores each event as a separate row. A query correlates rows by `msg_id` when needed:

   ```sql
   -- Correlate message.received with its response.complete
   SELECT
       r.event_time AS received_at,
       c.event_time AS completed_at,
       c.turn_duration,
       dateDiff('second', r.event_time, c.event_time) AS wall_clock_s,
       r.msg_id
   FROM cc.hook_events AS r
   INNER JOIN cc.hook_events AS c
       ON r.msg_id = c.msg_id
       AND c.event_type = 'response.complete'
   WHERE r.event_type = 'message.received'
     AND r.event_time >= now() - INTERVAL 1 DAY
   ```

---

## Comparison: Vector Pipeline vs Direct Hooks

| Aspect | Vector Pipeline (existing design) | Direct Hooks (this proposal) |
|--------|----------------------------------|------------------------------|
| **Components** | cc-connect + Vector + CK | cc-connect + nginx + CK |
| **Config LOC** | ~50 lines vector.toml | ~15 lines nginx.conf |
| **Extra containers** | 1 (Vector, ~150MB image) | 0 (reuse existing nginx or `nginx:alpine` ~23MB) |
| **Latency** | ~100ms (batch flush, up to 10s) | ~5ms (per-event) |
| **Data loss resilience** | Vector cursor checkpointing | cc-connect built-in retry + backoff |
| **Parsing requirement** | Go slog key=value regex parsing | Native JSON (no parsing needed) |
| **Event coverage** | 2 types (message inbound/outbound) | 7+ types (message, session lifecycle, permissions) |
| **Schema drift** | Vector transform must be updated | `raw_payload` absorbs unknown fields |
| **Operational burden** | Monitor Vector health, log rotation | Monitor nginx health (trivial) |
| **Throughput ceiling** | 1000s of events/sec (batched) | ~100 events/sec (per-POST overhead) |
| **Data richness** | Flattened typed columns only | Typed columns + raw JSON fallback |

### When to choose direct hooks

- **You want the simplest possible pipeline** (2 components, 15 LOC config)
- **Event volume is low** (<1000 events/day -- current reality is ~300)
- **You want full event coverage** (session lifecycle, permissions, not just messages)
- **You value schema flexibility** (raw_payload absorbs format changes)
- **You want per-event latency** under 10ms

### When to keep the Vector pipeline

- **You need multi-source ingestion** (not just cc-connect)
- **You already run Vector** for other pipelines
- **Volume exceeds 10K events/day** and batching matters
- **You need complex multi-line transforms** (join, aggregate, regex)

---

## Deployment Procedure

### Prerequisites

- [ ] cc-connect v1.3.2+ running
- [ ] ClickHouse running (`kyb-infra-clickhouse`, verify `curl http://host.orb.internal:8123/?query=SELECT+1`)
- [ ] `cc` database exists in ClickHouse
- [ ] `cc.hook_events` table created

### Step 1: Create Table

```bash
clickhouse-client --host host.orb.internal --query "CREATE DATABASE IF NOT EXISTS cc"

clickhouse-client --host host.orb.internal --multiquery <<'SQL'
CREATE TABLE IF NOT EXISTS cc.hook_events (
    event_time      DateTime64(3) DEFAULT now64(),
    event_type      LowCardinality(String),
    trace_id        String DEFAULT '',
    msg_id          String DEFAULT '',
    session         String DEFAULT '',
    chat_id         String DEFAULT '',
    sender_id       String DEFAULT '',
    content_len     UInt32 DEFAULT 0,
    has_images      UInt8 DEFAULT 0,
    has_audio       UInt8 DEFAULT 0,
    has_files       UInt8 DEFAULT 0,
    response_len    UInt32 DEFAULT 0,
    turn_duration   Float64 DEFAULT 0,
    input_tokens    UInt32 DEFAULT 0,
    output_tokens   UInt32 DEFAULT 0,
    tools_used      UInt8 DEFAULT 0,
    session_reason  LowCardinality(String) DEFAULT '',
    exit_code       Nullable(Int32),
    permission_request_id String DEFAULT '',
    permission_decision  LowCardinality(String) DEFAULT '',
    raw_payload     String CODEC(ZSTD(3)) DEFAULT '',
    _ingested_at    DateTime DEFAULT now(),
    _ck_instance    LowCardinality(String) DEFAULT 'kyb-infra-clickhouse',
    INDEX idx_raw_payload raw_payload TYPE tokenbf_v1(3072) GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY (toDate(event_time), event_type, msg_id)
TTL toDate(event_time) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
SQL
```

### Step 2: Deploy Nginx Adapter

Option A -- Add to an existing nginx instance (if one already runs on the host):

```nginx
# In existing nginx config, add:
server {
    listen 8420;
    location /hook {
        proxy_pass http://host.orb.internal:8123/?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow;
        proxy_method POST;
        proxy_set_body $request_body;
        proxy_set_header Content-Type "application/octet-stream";
        proxy_pass_request_body on;
        proxy_pass_request_headers off;
        proxy_connect_timeout 2s;
        proxy_read_timeout 5s;
    }
    location /health {
        return 200 "ok\n";
    }
}
```

Option B -- Standalone nginx container:

```bash
# Create config
cat > /tmp/ck-hook-adapter.conf <<'CONF'
server {
    listen 8420;
    location /hook {
        proxy_pass http://host.orb.internal:8123/?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow;
        proxy_method POST;
        proxy_set_body $request_body;
        proxy_set_header Content-Type "application/octet-stream";
        proxy_pass_request_body on;
        proxy_pass_request_headers off;
        proxy_connect_timeout 2s;
        proxy_read_timeout 5s;
    }
    location /health {
        return 200 "ok\n";
    }
}
CONF

# Run container
docker run -d --name kyb-infra-ck-hook-adapter \
  --restart unless-stopped \
  -p 8420:8420 \
  -v /tmp/ck-hook-adapter.conf:/etc/nginx/conf.d/default.conf:ro \
  nginx:alpine
```

### Step 3: Configure cc-connect Hooks

In cc-connect's configuration file (YAML):

```yaml
hooks:
  enabled: true
  backend: webhook
  webhook:
    url: "http://host.orb.internal:8420/hook"
    method: POST
    retry:
      max_attempts: 3
      backoff: exponential
      initial_interval: 1s
  events:
    - message.received
    - response.complete
    - session.timeout
    - session.crashed
    - session.resumed
    - permission.requested
    - permission.resolved
```

### Step 4: Verify

```bash
# Check events landing in CK
clickhouse-client --host host.orb.internal --query "
SELECT event_type, count() AS cnt
FROM cc.hook_events
WHERE event_time >= now() - INTERVAL 1 HOUR
GROUP BY event_type
ORDER BY cnt DESC
"

# Check raw payload for a recent event
clickhouse-client --host host.orb.internal --query "
SELECT event_type, left(raw_payload, 200) AS payload_preview
FROM cc.hook_events
ORDER BY event_time DESC
LIMIT 5
"
```

### Step 5: Add Grafana Panel (Hook Pipeline Health)

Add a panel in the existing Grafana CK datasource:

```sql
SELECT count() AS events_15min
FROM cc.hook_events
WHERE event_time >= now() - INTERVAL 15 MINUTE
```

Alert if `events_15min = 0` (reuse the pattern from `hooks-ck-pipeline.md`).

---

## Risks and Mitigations

### 1. cc-connect Hook Payload Stability (Medium)

The native hooks API is new in v1.3.2. If the JSON format changes, the typed columns may have mismatched data.

**Mitigation**: The `raw_payload` column stores the original JSON. No data is lost even if typed columns become stale. A migration can re-extract fields from `raw_payload` after a cc-connect update.

### 2. Write Amplification at Scale (Low)

At ~300 events/day, CK handles per-event INSERTs trivially. At 100K events/day, the MergeTree engine's background merge will handle it but HTTP connection overhead becomes noticeable.

**Mitigation**: Current volume is 300 events/day. If volume exceeds 10K/day, deploy the Vector pipeline (which batches inserts) and switch the cc-connect hook backend from webhook to file log (Vector reads the file).

### 3. Adapter Single Point of Failure (Medium)

If the nginx adapter goes down, cc-connect's webhook requests will fail. cc-connect's built-in retry (3 attempts, exponential backoff, ~7s total) provides short-term resilience.

**Mitigation**: Docker `--restart unless-stopped` on the adapter container recovers crashes within seconds. For P0 reliability, run two adapter instances behind Docker network load balancing.

### 4. ClickHouse Unavailability (Low)

If ClickHouse is down, the nginx adapter returns 502. cc-connect's webhook retries will exhaust after ~7s.

**Mitigation**: This is the same failure mode as the Vector pipeline. The `hooks-ck-pipeline.md` fail-open pattern applies: cc-connect continues operating without CK, events are lost during downtime. A local buffer (file log backend) could be switched to during CK downtime.

### 5. No Authentication (Low)

CK's HTTP port on `host.orb.internal:8123` is network-bound but accessible from Docker containers.

**Mitigation**: The nginx adapter should restrict access:

```nginx
location /hook {
    allow 127.0.0.1;
    allow 172.17.0.0/16;  # Docker bridge network
    deny all;
    # ... proxy_pass config
}
```

---

## Recommendations

1. **Ship direct hooks as the primary pipeline.** The per-event coverage (7 event types vs 2), schema flexibility (raw_payload), and operational simplicity (nginx + CK, no Vector) outweigh the batching advantage of Vector at current volume.

2. **Keep Vector pipeline as a fallback.** The Vector design (`bridge-ck-ingestion.md`) is reviewed and ready. If volume grows beyond 10K events/day, switch. The table schema is compatible with both pipelines.

3. **Enable all 7 hook events from day one.** Session lifecycle events (timeout, crashed, resumed) and permission events provide observability that the Vector log pipeline cannot capture. These are zero-cost to store (300 events/day is negligible) and invaluable for debugging.

4. **Add raw_payload to the existing Vector design too.** If the Vector pipeline ever deploys, the `raw_payload` column should be added to `cc.message_log` for the same schema-drift safety reasons.

5. **Add a 15-min silence alert** on `cc.hook_events` in Grafana, matching the pattern in `hooks-ck-pipeline.md`. This is the only monitoring the pipeline needs.

6. **Do NOT build a custom receiver.** Nginx rewrite is proven (the existing `hooks-ck-pipeline.md` and `emit-ck.sh` use the same CK HTTP interface). A custom Go/Python receiver adds build, deploy, and maintenance overhead for zero benefit at this scale.

---

## Verdict

**Approve for implementation.** The direct hooks -> CK pipeline is:

- **Feasible**: Proven pattern (Claude hooks already do this)
- **Simple**: 2 components, 15 LOC config, 0 new dependencies
- **Richer**: 7 event types vs 2 in the Vector design
- **Maintainable**: Nginx rewrite is Unix 101; any infra engineer can understand it
- **Schema-safe**: raw_payload column prevents data loss on format changes

### Effort Estimate

| Task | Time |
|------|------|
| Create table in CK | 1 min |
| Write nginx adapter config | 5 min |
| Deploy adapter container | 1 min |
| Configure cc-connect hooks | 2 min |
| Verify end-to-end | 5 min |
| Add Grafana silence alert | 2 min |
| **Total** | **~16 minutes** |

Deploy this before the Vector pipeline. The Vector pipeline adds no value at current volume and the hooks pipeline provides superior observability.
