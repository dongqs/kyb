---
decision: 稍后做
---

# cc-connect WebSocket Stability Monitoring

**Date**: 2026-05-23
**Scope**: Monitor Feishu WebSocket connection health for cc-connect: reconnect storms, stale connections, message gaps, and silent failures. Integrates with existing OTel observability (`otel-cc-connect.md`) and the 5-minute patrol system.

---

## 1. Background

cc-connect maintains a long-lived WebSocket connection to the Feishu API for real-time message delivery. This connection is the single point of failure for the entire bridge -- if the WS drops, all Feishu bot messages are lost until reconnect succeeds.

Current monitoring (via `cc-healthcheck`) only checks:
- Container is running
- Docker health status is "healthy"
- Feishu tenant access token is obtainable

These are necessary but not sufficient. A WS connection can appear healthy (container up, token valid) while silently failing:
- WebSocket reconnecting every few minutes (flapping)
- Connection alive but no messages received for hours (zombie)
- Heartbeat responses delayed beyond timeout (latent)

This document defines the **four WS health signals** to track, how to collect them, and how to alert on degradation.

---

## 2. The Four Signals

### 2.1 Reconnect Count (`cc.ws.reconnects`)

**What it measures**: Number of WebSocket reconnections in a time window (total, rate, consecutive).

**Why it matters**:
| Pattern | Interpretation |
|---------|---------------|
| 0 reconnects/day | Stable -- ideal |
| 1-2 reconnects/day | Normal maintenance (token refresh, network blip) |
| 5+ reconnects/hour | **Reconnect storm** -- indicates systemic problem (bad token, proxy flapping, Feishu-side instability) |
| Consecutive reconnects without stable period | Crash loop -- WS connects then immediately drops |

**Data source**: cc-connect logs lines containing `reconnect`, `websocket: connected`, `websocket: closed`, or similar. Capture as structured events.

**Implementation (log parsing)**:

```bash
# From cc-connect logs (via docker logs or Vector)
docker logs kyb-infra-cc-connect 2>&1 | grep -iE '(reconnect|websocket.*(connected|closed|disconnect))'
```

**Implementation (OTel counter)**:

| Metric | Type | Attributes |
|--------|------|------------|
| `cc.ws.reconnects_total` | Counter | `reason` (timeout / close / error / unknown) |
| `cc.ws.reconnects_consecutive` | Gauge | (none) -- current streak without stable period |

**Stable period definition**: A connection lasting >= 5 minutes is "stable". If a reconnect happens < 5 minutes after the previous one, it increments the consecutive counter.

### 2.2 Connection Age (`cc.ws.connection_age_seconds`)

**What it measures**: How long the current WebSocket connection has been alive.

**Why it matters**:
| Age | Interpretation |
|-----|---------------|
| > 24h | Normal -- expected lifetime |
| 1-24h | Acceptable, but younger than expected may indicate recent restart |
| < 1h | Recently reconnected -- normal unless frequency is high |
| Always < 5min | **Flapping** -- connection never stabilizes |

**Data source**: cc-connect logs the WS connect timestamp. Compare against current time.

**Implementation (OTel gauge)**:

| Metric | Type | Attributes |
|--------|------|------------|
| `cc.ws.connection_age_seconds` | Gauge | `session_id` (ws session identifier) |
| `cc.ws.connection_stable` | Gauge | 1 if age >= 300s, 0 otherwise |

**Tracking across reconnects**: On each new WS connection, record the old connection age as a histogram value (so we can see distribution of connection lifetimes) and reset the gauge.

| Metric | Type | Attributes |
|--------|------|------------|
| `cc.ws.connection_lifetime_seconds` | Histogram | `disconnect_reason` (close / error / timeout / expected) |

### 2.3 Message Gap (`cc.ws.message_gap_seconds`)

**What it measures**: Time elapsed since the last message received from the Feishu WebSocket.

**Why it matters**:
- Feishu sends a periodic heartbeat/ping (typically every 30-60s). If no message arrives for > 2x the expected interval, the connection is likely stale.
- For high-traffic bots, message gaps of > 5 minutes during business hours indicate a problem.
- This catches the "zombie connection" scenario where the WS is open but no data flows.

**Data source**: Timestamp of every event received from the Feishu WebSocket. In practice, this is the `feishu.message.receive` span in OTel traces (from `otel-cc-connect.md`), plus any WS-level pings/heartbeats.

**Implementation (OTel)**:

| Metric | Type | Attributes |
|--------|------|------------|
| `cc.ws.last_message_timestamp` | Gauge | `chat_type` -- unix timestamp of last received message |
| `cc.ws.message_gap_seconds` | Gauge | computed = `now() - last_message_timestamp` |
| `cc.ws.messages_per_minute` | Gauge | rolling 5-minute message rate |

**For the non-trace path (log-based)**:

Extract message timestamps from cc-connect logs:

```bash
docker logs kyb-infra-cc-connect --tail 100 2>&1 \
  | grep -oP '\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}' \
  | tail -1
```

Compare against wall clock. If > 5 minutes, the connection is suspect.

### 2.4 Heartbeat Miss (`cc.ws.heartbeat_misses`)

**What it measures**: Count of expected Feishu WS heartbeats that did not arrive within the expected interval.

**Why it matters**:
- Feishu WebSocket protocol sends periodic pings (implementation-specific, typically 30-60s).
- If cc-connect implements WS-level ping/pong, track how many pongs are missed.
- Even without WS-level ping, the _application-level_ heartbeat (periodic Feishu events) serves as a proxy.

**Data source**:
- WS-level: cc-connect's internal ping/pong counters (if instrumented)
- App-level: timestamps between successive Feishu events

**Implementation (OTel)**:

| Metric | Type | Attributes |
|--------|------|------------|
| `cc.ws.heartbeats_expected_total` | Counter | `type` (ws_ping / app_event) |
| `cc.ws.heartbeats_received_total` | Counter | `type` |
| `cc.ws.heartbeats_missed_total` | Counter | `type` -- computed = expected - received |
| `cc.ws.heartbeat_miss_ratio` | Gauge | = missed / expected over last 5m window |

**Threshold**: If `heartbeat_miss_ratio > 0.5` over any 5-minute window, the connection is degraded.

---

## 3. Architecture

### 3.1 Data Sources

```
┌──────────────────────────────────────────────────┐
│                  cc-connect                       │
│                                                   │
│  ┌──────────────────┐    ┌─────────────────────┐  │
│  │ WebSocket Client  │    │   OTel Instrumentation│  │
│  │                   │    │                     │  │
│  │ connect/disconnect│    │ cc.ws.reconnects    │  │
│  │ events            │───▶│ cc.ws.connection_age│  │
│  │ message receive   │    │ cc.ws.message_gap   │  │
│  │ ping/pong         │    │ cc.ws.heartbeats    │  │
│  └──────────────────┘    └──────────┬──────────┘  │
│                                     │ OTLP        │
└─────────────────────────────────────┼─────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              │                       ▼                       │
              │          ┌──────────────────────┐             │
              │          │   OTel Collector     │             │
              │          │                      │             │
              │          │  → Tempo (traces)    │             │
              │          │  → Prometheus (met)  │             │
              │          │  → ClickHouse (logs) │             │
              │          └──────────────────────┘             │
              │                                               │
              │  Fallback path (no OTel in cc-connect):      │
              │  Vector → docker logs → parse → CK           │
              │                                               │
              └───────────────────────────────────────────────┘
```

### 3.2 Preferred Path: OTel Metrics Direct from cc-connect

If cc-connect is already instrumented with OTel (see `otel-cc-connect.md`), add the four WS health metrics to the existing OTel metrics pipeline:

```yaml
# OTel Collector config addition
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

processors:
  batch:
    timeout: 1s

exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: cc_connect
    resource_to_telemetry_conversion:
      enabled: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [prometheus]
```

### 3.3 Fallback Path: Log-Based via Vector

If cc-connect does not yet export OTel metrics, parse its logs with Vector:

```toml
# vector.toml snippet
[sources.cc_connect_logs]
type = "docker_logs"
include_containers = ["kyb-infra-cc-connect"]

[transforms.cc_ws_events]
type = "remap"
inputs = ["cc_connect_logs"]
source = '''
  if match!(.message, r'reconnect|websocket.*connected|websocket.*closed') {
    .event_type = "ws_reconnect"
    .timestamp = now()
  } else if match!(.message, r'received.*message') {
    .event_type = "ws_message"
    .timestamp = now()
  }
'''

[sinks.cc_ws_metrics]
type = "prometheus_exporter"
inputs = ["cc_ws_events"]
default_namespace = "cc_connect"
```

### 3.4 Patrol Integration

The existing 5-minute patrol system (`5min-patrol-guide.md`) can check WS health without OTel at all, by reading the latest metrics from a state file written by cc-connect:

```bash
# ~/.kyb/bin/cc-ws-health (proposed)
# Read WS health from cc-connect state
WS_STATE=$(docker exec kyb-infra-cc-connect cat /tmp/ws-health.json 2>/dev/null || echo '{}')

CONNECTION_AGE=$(echo "$WS_STATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('connection_age_seconds', -1))")
LAST_MESSAGE=$(echo "$WS_STATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_message_ago_seconds', -1))")
RECONNECTS_1H=$(echo "$WS_STATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reconnects_last_hour', -1))")

# Alert thresholds
if [ "$RECONNECTS_1H" -gt 10 ]; then
  echo "WARNING: cc-connect WS reconnect storm ($RECONNECTS_1H reconnects in last hour)"
fi
if [ "$CONNECTION_AGE" -gt 0 ] && [ "$CONNECTION_AGE" -lt 300 ]; then
  echo "WARNING: cc-connect WS connection age only ${CONNECTION_AGE}s (unstable)"
fi
if [ "$LAST_MESSAGE" -gt 300 ]; then
  echo "WARNING: cc-connect WS no message for ${LAST_MESSAGE}s (zombie connection)"
fi
```

This patrol check integrates into `patrol.check.health` as an additional sub-check (see `otel-patrol.md`):

| Attribute | Type | Description |
|-----------|------|-------------|
| `healthcheck.ws.connected` | bool | WS currently connected |
| `healthcheck.ws.connection_age_seconds` | int | Age of current WS connection |
| `healthcheck.ws.reconnects_1h` | int | Reconnect count in last 60 minutes |
| `healthcheck.ws.seconds_since_last_message` | int | Gap since last WS message |
| `healthcheck.ws.status` | string | `ok` / `flapping` / `zombie` / `disconnected` |

---

## 4. WS Health State Machine

```
                    ┌──────────────┐
     start ────────▶│ Disconnected │
                    └──────┬───────┘
                           │ connect
                           ▼
                    ┌──────────────┐
                    │  Connecting   │
                    └──────┬───────┘
                           │ success
                           ▼
                    ┌──────────────┐ ◀────────────┐
              ┌────▶│   Connected   │              │
              │     └──────┬───────┘              │
              │            │                      │
              │     ┌──────┴────────┐             │
              │     │  Age ≥ 300s?  │─── no ──────┤
              │     └──────┬────────┘   (flapping)│
              │            │ yes                  │
              │            ▼                      │
              │     ┌──────────────┐              │
              │     │    Stable    │              │
              │     └──────┬───────┘              │
              │            │                      │
              │     ┌──────┴────────┐             │
              │     │ Message gap   │─── >5m ─────┤
              │     │ > threshold?  │  (zombie)   │
              │     └──────┬────────┘             │
              │            │ no                   │
              │     ┌──────┴────────┐             │
              │     │ Heartbeat     │─── >50% ────┤
              │     │ miss ratio >  │  (degraded) │
              │     │ threshold?    │             │
              │     └──────┬────────┘             │
              │            │ no                   │
              └────────────┘                      │
                                                  │
                  disconnect ─────────────────────┘
```

**State definitions**:

| State | Criteria | Severity |
|-------|----------|----------|
| **Disconnected** | WS not connected (startup, crash) | P0 |
| **Connecting** | WS connect in progress | Info |
| **Connected** | WS connected but < 5 min old (flapping window) | Warn |
| **Stable** | Connected >= 5 min, messages flowing, heartbeats OK | OK |
| **Flapping** | Connected but age < 5 min and reconnect count > 5/h | P1 |
| **Zombie** | Connected >= 5 min but no message for > 5 min | P1 |
| **Degraded** | Connected >= 5 min but heartbeat miss ratio > 50% | P2 |

---

## 5. Metrics Summary

### 5.1 OTel Metrics (preferred)

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `cc.ws.reconnects_total` | Counter | `reason` | Total reconnects |
| `cc.ws.reconnects_consecutive` | Gauge | -- | Current consecutive reconnect streak |
| `cc.ws.connection_age_seconds` | Gauge | `session_id` | Age of current WS connection |
| `cc.ws.connection_lifetime_seconds` | Histogram | `disconnect_reason` | Lifetime of completed connections (for distribution analysis) |
| `cc.ws.connection_stable` | Gauge | -- | 1 if age >= 300s, 0 otherwise |
| `cc.ws.last_message_timestamp` | Gauge | -- | Unix timestamp of last received message |
| `cc.ws.message_gap_seconds` | Gauge | -- | Seconds since last message |
| `cc.ws.messages_per_minute` | Gauge | -- | Rolling 5-min message rate |
| `cc.ws.heartbeats_expected_total` | Counter | `type` | Expected heartbeats |
| `cc.ws.heartbeats_received_total` | Counter | `type` | Received heartbeats |
| `cc.ws.heartbeats_missed_total` | Counter | `type` | Missed heartbeats |
| `cc.ws.heartbeat_miss_ratio` | Gauge | -- | Miss ratio over last 5 min |
| `cc.ws.state` | Gauge | `state` | Current state (0=disconnected, 1=connecting, 2=connected, 3=stable, 4=flapping, 5=zombie, 6=degraded) |

### 5.2 Prometheus Recording Rules

For alerting and dashboard efficiency, pre-compute derived metrics:

```yaml
groups:
  - name: cc_ws_health
    interval: 15s
    rules:
      # Reconnect rate (per minute)
      - record: cc_ws:reconnects_per_minute:rate5m
        expr: rate(cc_ws_reconnects_total[5m])

      # Consecutive reconnects (reset when stable)
      - record: cc_ws:consecutive_reconnects:max
        expr: cc_ws_reconnects_consecutive

      # Message gap (promote gauge to alertable form)
      - record: cc_ws:message_gap_seconds:max
        expr: cc_ws_message_gap_seconds

      # Composite health (0 = healthy, 1 = degraded, 2 = down)
      - record: cc_ws:health_score
        expr: |
          clamp_max(
            (cc_ws_reconnects_consecutive > 0) +
            (cc_ws_message_gap_seconds > 300) +
            (cc_ws_heartbeat_miss_ratio > 0.5) +
            (cc_ws_connection_stable == 0),
          2)
```

### 5.3 Grafana Dashboard Panels

Recommended panels for a WS health dashboard:

| Panel | Type | Query | Description |
|-------|------|-------|-------------|
| WS State | Stat / State timeline | `cc_ws_state` | Current WS state (colored by severity) |
| Connection Age | Stat | `cc_ws_connection_age_seconds` | How long current connection has been alive |
| Reconnect Count | Time series | `rate(cc_ws_reconnects_total[5m])` | Reconnects per minute over time |
| Message Gap | Time series | `cc_ws_message_gap_seconds` | Time since last message (spikes = silence) |
| Heartbeat Miss Ratio | Time series | `cc_ws_heartbeat_miss_ratio` | % of missed heartbeats |
| Connection Lifetime | Heatmap | `cc_ws_connection_lifetime_seconds` bucket | Distribution of connection lifetimes |
| Health Score | Stat (color-coded) | `cc_ws_health_score` | 0=green, 1=yellow, 2=red |
| Messages Per Minute | Time series | `cc_ws_messages_per_minute` | Application-level throughput (context: is high reconnect rate causing message loss?) |

---

## 6. Alerting Rules

### 6.1 Prometheus Alert Rules

```yaml
groups:
  - name: cc_ws_alerts
    interval: 30s
    rules:
      # ── P0: Complete disconnect ──
      - alert: CCWSDisconnected
        expr: cc_ws_state{state="disconnected"} == 1
        for: 1m
        labels:
          severity: p0
          team: infra
        annotations:
          summary: "cc-connect WebSocket disconnected"
          description: >-
            cc-connect has no WebSocket connection to Feishu for > 1 minute.
            Messages are NOT being received. Check container logs and network.

      # ── P1: Reconnect storm ──
      - alert: CCWSReconnectStorm
        expr: rate(cc_ws_reconnects_total[15m]) > 0.1
        for: 5m
        labels:
          severity: p1
          team: infra
        annotations:
          summary: "cc-connect WebSocket reconnect storm"
          description: >-
            cc-connect reconnecting at {{ $value | humanize }} reconnects/min
            for the last 5 minutes. Network instability or token issue likely.

      # ── P1: Zombie connection ──
      - alert: CCWSZombie
        expr: cc_ws_message_gap_seconds > 300
        for: 5m
        labels:
          severity: p1
          team: infra
        annotations:
          summary: "cc-connect WebSocket zombie (no messages)"
          description: >-
            No messages received on cc-connect WebSocket for
            {{ $value | humanizeDuration }}. Connection open but silent.

      # ── P2: Flapping ──
      - alert: CCWSFlapping
        expr: cc_ws:consecutive_reconnects:max > 5
        for: 2m
        labels:
          severity: p2
          team: infra
        annotations:
          summary: "cc-connect WebSocket flapping"
          description: >-
            {{ $value }} consecutive reconnects without stable period.
            Connection starts then drops repeatedly.

      # ── P2: Degraded heartbeats ──
      - alert: CCWSDegradedHeartbeat
        expr: cc_ws_heartbeat_miss_ratio > 0.5
        for: 5m
        labels:
          severity: p2
          team: infra
        annotations:
          summary: "cc-connect WebSocket heartbeat degradation"
          description: >-
            {{ $value | humanizePercentage }} of heartbeats missed
            in last 5 minutes. Connection quality degraded.

      # ── P3: Unstable (connected but not stable) ──
      - alert: CCWSUnstable
        expr: cc_ws_connection_stable == 0
        for: 30m
        labels:
          severity: p3
          team: infra
        annotations:
          summary: "cc-connect WebSocket not stabilizing"
          description: >-
            cc-connect has not maintained a stable WS connection (> 5 min)
            for the last 30 minutes.
```

### 6.2 Alert Severity Matrix

| Alert | Latency | Impact | Auto-recovery |
|-------|---------|--------|---------------|
| Disconnected (P0) | Instant message loss | All messages lost | Docker restart (cc-healthcheck) |
| Reconnect storm (P1) | Gradual, messages may be lost during reconnects | Degraded | Depends on root cause |
| Zombie (P1) | Messages silently lost for 5+ min | Total message loss during window | Docker restart, then root cause |
| Flapping (P2) | Intermittent connectivity | Annoyance, possible duplicate messages | Usually self-resolves |
| Degraded heartbeat (P2) | Latency increase only | None immediate, leading indicator | Self-resolves if transient |
| Not stabilizing (P3) | Connection never durable | Eventual message loss | Manual investigation |

---

## 7. Implementation Roadmap

### Phase 0: Log-Based Quick Win (1 hour)

Goal: Get WS health data flowing immediately with zero code changes to cc-connect.

- [ ] Add Vector transform to parse cc-connect logs for WS events (reconnect, connect, disconnect)
- [ ] Export as Prometheus metrics from Vector
- [ ] Add one Grafana panel for reconnect count
- [ ] Add patrol check: `~/.kyb/bin/cc-ws-health` reads logs for last message time

### Phase 1: cc-connect Instrumentation (1 day)

Goal: First-class OTel metrics from cc-connect's WebSocket client.

- [ ] Add OTel metrics counters/gauges to the WS client wrapper
- [ ] Track connect/disconnect timestamps and reason codes
- [ ] Track per-message timestamps (reuse existing `feishu.message.receive` trace timestamps)
- [ ] Export `cc_ws_state` gauge for the state machine
- [ ] Export `/tmp/ws-health.json` for patrol consumption

### Phase 2: Alerting + Dashboard (0.5 day)

- [ ] Deploy Prometheus alerting rules
- [ ] Create Grafana WS health dashboard (panels in section 5.3)
- [ ] Wire P0 alert to Feishu notification (via existing patrol report channel)
- [ ] Test: kill WS connection, verify alert fires within 2 minutes

### Phase 3: Patrol Integration (0.5 day)

- [ ] Integrate `cc-ws-health` check into `patrol.check.health` span
- [ ] Add WS health attributes to OTel patrol traces (see `otel-patrol.md`)
- [ ] Patrol raises anomaly when WS state != stable for > 15 minutes

---

## 8. Known Incidents & Tuning

### Common Reconnect Causes

| Cause | Symptom | Fix |
|-------|---------|-----|
| Feishu token expired | Reconnect every 2h (token TTL) | Ensure token refresh on reconnect |
| Network proxy flapping | Burst reconnects, sibling patrol also affected | Check proxy container health |
| Feishu API sidecar restart | Single reconnect, immediately stable | Ignore (expected) |
| Container OOM | cc-connect process killed, WS drops | Increase memory limit |
| DNS resolution failure | Connect timeout, repeated retries | Add `dns` check to patrol |

### Threshold Tuning

Default thresholds are conservative. After 2 weeks of data collection, tune based on observed P95 behavior:

| Signal | Initial Threshold | Tuning Method |
|--------|-------------------|---------------|
| Reconnect rate | > 0.1/min (6/h) | Set to P95 + 20% |
| Message gap | > 300s (5 min) | Set to P95 + 50% (quiet periods are normal) |
| Heartbeat miss ratio | > 50% | Set to P99 of observed miss rate |
| Consecutive reconnects | > 5 | Set based on max observed without stable period |

---

## 9. References

- OTel tracing for cc-connect: `docs/infra/reviews/otel-cc-connect.md`
- Patrol tracing: `docs/infra/reviews/otel-patrol.md`
- Infrastructure patrol guide: `docs/infra/5min-patrol-guide.md`
- Observability design overview: `docs/infra/observability-design.md`
- `~/.kyb/bin/cc-healthcheck` -- existing container health check script
- Feishu WebSocket API docs: https://open.feishu.cn/document/server-docs/event-subscription/guide
