---
decision: 现在就做
---

# cc-connect Hooks Configuration -- Standby

**Status**: Ready for deployment
**Date**: 2026-05-23
**Source Docs**:
- [review-bridge-hooks-C1.md](../reviews/review-bridge-hooks-C1.md) -- Discovery: cc-connect v1.3.2 has native hooks
- [hooks-direct-ck.md](../reviews/hooks-direct-ck.md) -- Direct HTTP POST to ClickHouse
- [hooks-kafka.md](../reviews/hooks-kafka.md) -- Kafka pipeline via REST Proxy

---

## Decision

**Use Direct-to-ClickHouse configuration (TOML).** No Kafka. No Vector. The cc-connect hooks POST directly to ClickHouse HTTP endpoint.

Rationale (from hooks-direct-ck.md):
- ~90 messages/day, ~34 KB/day -- Kafka is overkill at this volume
- Zero additional infrastructure -- no Vector container, no Kafka broker
- Simpler debugging -- one config file, one data path
- Fail-open by design -- hook failure never blocks message processing

Switch to Kafka if:
- Multi-cluster deployment with unreliable WAN between cc-connect and ClickHouse
- Volume exceeds 1000 events/day and zero event loss during CK downtime is required
- Kafka already exists as a unified event bus for other pipelines

---

## config.toml Hooks Block

File location: `/root/.cc-connect/config.toml`

### Full config (app + hooks)

```toml
[app]
app_id = "cli_xxxxx"
app_secret = "plaintext-secret"

# ──────────────────────────────────────────────
# cc-connect Native Hooks -- Direct to ClickHouse
# ──────────────────────────────────────────────
[hooks]

# Webhook backend: POST directly to ClickHouse HTTP endpoint
[hooks.webhook]
enabled = true
url = "http://host.orb.internal:8123/?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow"
method = "POST"
timeout_ms = 5000

[hooks.webhook.retry]
max_retries = 2
backoff_base_ms = 500
backoff_max_ms = 5000

[hooks.webhook.headers]
Content-Type = "application/json"
# X-ClickHouse-User = "default"
# X-ClickHouse-Key = ""

# Subscribe to specific events (default: all)
[hooks.webhook.events]
subscribe = [
    "message.received",
    "response.complete",
    "session.timeout",
    "session.crashed",
    "session.resumed",
    "permission.requested",
    "heartbeat",
]
```

### Notes

1. **URL query parameter**: The INSERT statement is embedded as a URL query param (`?query=...`). If cc-connect's webhook backend strips query params from the URL, deploy a thin nginx shim (5 lines, zero business logic) to translate path to query. See hooks-direct-ck.md section 4.1.

2. **Retry configuration**: 2 retries with exponential backoff (500ms, 1000ms). Total window ~1.5s before giving up. On exhaustion, cc-connect logs a warning and continues -- fail-open.

3. **Events**: 6 lifecycle events + optional heartbeat for dead-man's-switch monitoring. Subscribe to all during initial deployment, trim later.

4. **Heartbeat**: Periodic liveness signal from cc-connect. If heartbeats stop arriving in CK, an alert fires indicating the hooks pipeline is broken.

---

## ClickHouse Schema

```sql
CREATE TABLE cc.hook_events (
    event_time      DateTime64(3) DEFAULT now(),
    event_type      LowCardinality(String),
    hook_version    LowCardinality(String),

    -- Correlation
    trace_id        String,
    chat_id         String,
    chat_type       LowCardinality(String),

    -- Sender info
    sender_id       String,
    sender_type     LowCardinality(String),

    -- Message details
    message_id      String,
    message_type    LowCardinality(String),
    content_text    String,
    content_len     UInt32,
    has_images      UInt8,

    -- Session info
    session_id      String,
    agent_session   String,

    -- Response metrics (for response.complete)
    response_len    UInt32,
    turn_duration   Float64,
    input_tokens    UInt32,
    output_tokens   UInt32,
    tools_used      UInt8,

    -- Error info (for session.timeout, session.crashed)
    error_code      LowCardinality(String),
    error_message   String,

    -- Permission info (for permission.requested)
    permission_type         LowCardinality(String),
    permission_status       LowCardinality(String),

    -- Health info (for heartbeat)
    container_uptime UInt32,
    active_sessions UInt16,
    memory_mb       UInt16,

    -- Metadata
    cluster         LowCardinality(String) DEFAULT 'mac-orbstack',
    hostname        String,
    via_hook        Bool DEFAULT true
)
ENGINE = MergeTree
ORDER BY (toDate(event_time), event_type, chat_id)
TTL toDate(event_time) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

---

## Alternatives

### Kafka Pipeline (YAML config)

If the decision changes to use Kafka as a buffer (needed if CK is on a remote cluster), cc-connect hooks switch to YAML format targeting the Kafka REST Proxy:

```yaml
# /etc/cc-connect/hooks.yaml
hooks:
  webhooks:
    - url: "http://host.orb.internal:8082/topics/cc.hooks"
      events:
        - "message.received"
        - "response.complete"
        - "session.timeout"
        - "session.crashed"
        - "session.resumed"
        - "permission.requested"
      retry_count: 2
      retry_interval_ms: 1000
      timeout_ms: 5000
      headers:
        Content-Type: "application/vnd.kafka.json.v2+json"
        Accept: "application/vnd.kafka.v2+json"
```

This requires Redpanda (or cp-kafka-rest) on port 8082, a `cc.hooks` topic with 3 partitions, and ClickHouse Kafka Engine + Materialized View. See hooks-kafka.md for full schema and deployment steps.

---

## Deployment

1. Add hooks block to `/root/.cc-connect/config.toml`
2. Run ClickHouse DDL to create `cc.hook_events` table
3. Restart cc-connect container
4. Verify: send a test message through cc-connect and check CK
5. Add Grafana dashboard from hooks-direct-ck.md section 12
