---
decision: 稍后做
---

# Feishu API Rate Limit Monitoring

> **Status:** Design Document
> **Date:** 2026-05-23
> **Context:** Track Feishu API call volume, remaining quota, and rate limit violations per endpoint across all feishu-integrated services (cc-connect, lark-cli, healthcheck).

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Rate Limit Landscape](#2-rate-limit-landscape)
3. [Metrics Model](#3-metrics-model)
4. [Instrumentation Points](#4-instrumentation-points)
5. [Metrics Definition](#5-metrics-definition)
6. [Dashboards](#6-dashboards)
7. [Alert Rules](#7-alert-rules)
8. [Implementation Plan](#8-implementation-plan)

---

## 1. Problem Statement

Feishu APIs are subject to multiple tiers of rate limiting (per-app QPS, per-method QPS, monthly free-tier cap, per-user/per-chat sending limits). When a limit is exceeded:

- The API returns HTTP 429 with error codes `190004` (method rate limit) or `190005` (app rate limit)
- The monthly cap returns error `99991403` and blocks all app API calls until the next month
- There is no built-in dashboard or alert for approaching these limits

Without monitoring, rate limit hits cause silent failures (dropped messages, failed notifications) that are hard to distinguish from network or server errors.

### Current state

| Service | Client library | Rate limit handling |
|---------|---------------|-------------------|
| cc-connect | Custom Feishu SDK (Go) | Retry on 429 with backoff |
| lark-cli | Rust SDK | Retry on 429 |
| healthcheck | Shell + curl | No handling |
| Feishu webhook | HTTP POST | No handling (one-shot) |

No service currently exposes rate limit metrics or logs remaining quota.

---

## 2. Rate Limit Landscape

### 2.1 Limit tiers

| Tier | Scope | Limit | Error code | Reset |
|------|-------|-------|-----------|-------|
| **Monthly quota** | Per-tenant, all self-built apps combined | 10,000 calls/month (free tier) | `99991403` | 1st of month |
| **App QPS** | Per app_id, all endpoints combined | ~20 QPS | `190005` / 429 | 1-second sliding |
| **Method QPS** | Per endpoint path | Variable (e.g. send message 5 QPS per chat) | `190004` / 429 | 1-second sliding |
| **User/chat throttle** | Per open_id + chat_id | 5 QPS for send/reply | `190004` / 429 | 1-second sliding |
| **Batch send** | Per app per day | 500,000 total entries | `190005` / 429 | Daily |

### 2.2 Rate limit response headers

Feishu API responses include these headers (observed pattern):

```
X-Request-Id: <uuid>
X-Feishu-RateLimit-Limit: <total quota for window>
X-Feishu-RateLimit-Remaining: <remaining quota>
X-Feishu-RateLimit-Reset: <epoch seconds when quota resets>
```

Not all endpoints send all headers. The 429 response body contains:

```json
{
  "code": 190004,
  "msg": "method rate limit exceeded"
}
```

### 2.3 Tenant access token

Tenant access token (`tenant_access_token`) acquisition (`/auth/v3/tenant_access_token/internal`) has its own throttle: ~75 requests/hour. Exhausting this throttle blocks all API calls until the hour resets.

---

## 3. Metrics Model

### 3.1 Core metric dimensions

Every rate-limit-related metric is tagged with:

| Dimension | Description | Cardinality |
|-----------|-------------|-------------|
| `service` | Caller identity (cc-connect, lark-cli, healthcheck, webhook) | ~4 |
| `app_id` | Feishu app ID (prefix `cli_`) | ~2-5 |
| `endpoint` | Feishu API path, e.g. `/im/v1/messages` | ~20 |
| `method` | HTTP method | ~4 |
| `status` | HTTP status code family (2xx, 4xx, 5xx), or `rate_limited` | ~5 |

### 3.2 Derived dimensions (for rate limit events only)

| Dimension | Description | Cardinality |
|-----------|-------------|-------------|
| `limit_type` | `app`, `method`, `monthly`, `token_acquisition` | ~4 |
| `error_code` | Feishu error code, e.g. `190004`, `190005`, `99991403` | ~6 |

---

## 4. Instrumentation Points

### 4.1 Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌───────────────┐
│  cc-connect      │────>│  Metrics bridge   │────>│  Prometheus    │
│  (Go SDK)        │     │  (HTTP handler)    │     │  (scrape)      │
└─────────────────┘     └──────────────────┘     └───────┬───────┘
                                                          │
┌─────────────────┐                                      │
│  lark-cli        │────>(stdout structured logs)─────────┘
│  (Rust SDK)      │      Vector → OpenTelemetry
└─────────────────┘
                                                          │
┌─────────────────┐                                     ┌▼────────┐
│  healthcheck     │────>(shell metrics file)────────────>│ Grafana  │
│  (bash + curl)   │     node_exporter textfile           └─────────┘
└─────────────────┘
```

### 4.2 Where to instrument

Each HTTP call to a Feishu API passes through a thin client wrapper. That wrapper is the single instrumentation point:

1. **Before call**: increment `feishu_calls_total` (counter, pending status)
2. **After response**: increment `feishu_calls_total` with final status, observe latency
3. **Parse headers**: update `feishu_rate_limit_remaining` (gauge) from `X-Feishu-RateLimit-Remaining`
4. **On 429**: increment `feishu_rate_limit_hits_total` (counter) with `limit_type` and `error_code`
5. **On monthly cap (99991403)**: fire a critical metric event

### 4.3 Instrumentation by service

#### cc-connect (Go, priority)

Add a Prometheus metrics endpoint (`/metrics`) to cc-connect. The existing Feishu HTTP client wrapper in Go already has retry logic -- extend it to:

- Expose `promhttp.Handler` on a dedicated port (e.g. `:9102`)
- Wrap each HTTP call with `prometheus.NewTimer` for latency
- Parse response headers for rate limit info
- Track tenant token refresh separately (it is on a separate auth path)

#### lark-cli (Rust)

lark-cli runs as short-lived CLI commands. Instead of a metrics server, emit structured JSON log lines on stderr when rate limit events occur:

```json
{
  "timestamp": "...",
  "event": "feishu_rate_limit",
  "app_id": "cli_xxx",
  "endpoint": "/im/v1/messages",
  "limit_type": "method",
  "error_code": 190004,
  "remaining": 0,
  "reset_at": 1716000000
}
```

Vector collects these logs and converts them to Prometheus metrics via a `log2metric` transform.

#### healthcheck (bash + curl)

Use Prometheus `node_exporter` textfile collector. The healthcheck script writes a `.prom` file:

```
# HELP feishu_calls_total Total Feishu API calls from healthcheck
# TYPE feishu_calls_total counter
feishu_calls_total{endpoint="/im/v1/messages",status="200"} 42
# HELP feishu_rate_limit_remaining Remaining Feishu API quota
# TYPE feishu_rate_limit_remaining gauge
feishu_rate_limit_remaining{endpoint="auth"} 58
```

---

## 5. Metrics Definition

### 5.1 Prometheus metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `feishu_calls_total` | Counter | `service`, `app_id`, `endpoint`, `method`, `status` | Total Feishu API calls by endpoint and result |
| `feishu_call_duration_seconds` | Histogram | `service`, `app_id`, `endpoint`, `method` | Request latency to Feishu APIs (buckets: 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30) |
| `feishu_rate_limit_remaining` | Gauge | `service`, `app_id`, `endpoint` | Remaining quota from `X-Feishu-RateLimit-Remaining` header (per-endpoint) |
| `feishu_rate_limit_hits_total` | Counter | `service`, `app_id`, `endpoint`, `limit_type`, `error_code` | Count of 429 responses received |
| `feishu_monthly_quota_remaining` | Gauge | `app_id` | Estimated remaining monthly quota (decremented on every 99991403 or derived from tenant token endpoint) |
| `feishu_token_refresh_duration_seconds` | Histogram | `service`, `app_id` | Latency of tenant_access_token acquisition |
| `feishu_token_expires_at` | Gauge | `service`, `app_id` | Unix timestamp of current token expiry |

### 5.2 Metadata (via OpenTelemetry / structured logs)

For deep analysis, log each API call with:

| Field | Source |
|-------|--------|
| `trace_id` | Context propagation |
| `api_call_id` | `X-Request-Id` response header |
| `request_body_size` | Request payload bytes |
| `response_body_size` | Response payload bytes |
| `endpoint_group` | Derived category: `im`, `auth`, `bot`, `calendar`, `doc`, `drive` |

---

## 6. Dashboards

### 6.1 "Feishu API Health" dashboard

#### Row 1: Call Volume & Error Rate

```
Panel: API Calls per Second (sparkline per endpoint)
  - feishu_calls_total[5m] / 300
  - Color by endpoint, stack

Panel: Error Rate (%)
  - (sum(rate(feishu_calls_total{status=~"5..|429"}[5m])) / sum(rate(feishu_calls_total[5m]))) * 100
  - Threshold line at 5%, 10%

Panel: Rate Limit Hit Rate
  - sum(rate(feishu_rate_limit_hits_total[5m]))
  - Breakdown by limit_type (app vs method)
```

#### Row 2: Remaining Quota

```
Panel: Monthly Quota Remaining
  - feishu_monthly_quota_remaining
  - Single stat showing remaining calls this month
  - Red background when < 1000

Panel: Per-Endpoint Remaining Quota (heatmap)
  - feishu_rate_limit_remaining
  - Columns: endpoints, rows: time
  - Red when < 5 remaining
```

#### Row 3: Latency

```
Panel: P50/P90/P99 Latency by Endpoint
  - histogram_quantile(0.50/0.90/0.99, sum(rate(feishu_call_duration_seconds_bucket[5m])) by (le, endpoint))
  - Separate lines for each quantile

Panel: Token Refresh Latency
  - histogram_quantile(0.50/0.90/0.99, rate(feishu_token_refresh_duration_seconds_bucket[5m]))
  - Alert if P99 > 2s
```

#### Row 4: Top Talkers

```
Panel: Top Endpoints by Call Volume
  - topk(10, sum by(endpoint)(rate(feishu_calls_total[1h])))
  - Horizontal bar chart

Panel: Top 429 Recipients
  - topk(5, sum by(endpoint)(rate(feishu_rate_limit_hits_total[1h])))
  - Identify which endpoints are being throttled
```

### 6.2 "Feishu Monthly Quota Burn" panel (on main infra dashboard)

```
Panel: Monthly Quota Burn Rate
  - idelta(feishu_monthly_quota_remaining[1h])
  - Projected exhaustion date from 7-day average burn rate
```

---

## 7. Alert Rules

### 7.1 Critical alerts (P0-P1)

| Rule | Condition | Severity | Response |
|------|-----------|----------|----------|
| Monthly quota exhaustion | `feishu_monthly_quota_remaining < 500` | P1 | Review usage, cache more aggressively, consider paid plan |
| Monthly quota exhausted | `feishu_monthly_quota_remaining == 0` for > 5m | P0 | All Feishu API calls failing. Emergency: fall back to webhook-only notifications |
| Token acquisition failing | `rate(feishu_token_refresh_duration_seconds_count{status!="200"}[5m]) > 0` | P0 | App credentials invalid or auth endpoint unavailable. Check app_secret, network |

### 7.2 Warning alerts (P2-P3)

| Rule | Condition | Severity | Response |
|------|-----------|----------|----------|
| High app rate limit hit rate | `rate(feishu_rate_limit_hits_total{limit_type="app"}[5m]) > 0.1` | P2 | App is approaching global QPS ceiling. Reduce call frequency or add batching |
| Method rate limit spikes | `rate(feishu_rate_limit_hits_total{limit_type="method"}[5m]) > 1` | P2 | Specific endpoint being called too fast. Add client-side rate limiting per endpoint |
| Remaining quota low | `feishu_rate_limit_remaining < 5` for any endpoint | P2 | Per-endpoint quota nearly exhausted. Throttle calls to that endpoint |
| Latency P99 > 10s | `histogram_quantile(0.99, rate(...)[5m]) > 10` | P2 | Feishu API responding slowly. Could indicate Feishu-side degradation |
| High error rate | `rate(feishu_calls_total{status=~"5.."}[5m]) / rate(feishu_calls_total[5m]) > 0.05` | P2 | > 5% server errors from Feishu. Network or Feishu-side issue |

### 7.3 Informational alerts

| Rule | Condition | Severity | Response |
|------|-----------|----------|----------|
| Call volume spike | `sum(rate(feishu_calls_total[5m])) > 2 * sum(rate(feishu_calls_total[30m]))` | Info | Unexpected traffic pattern. Check if a new feature or loop is generating extra calls |
| Monthly quota burn rate change | Weekly average burn rate changed by > 50% | Info | Usage pattern shift. May require re-planning quota allocation |

---

## 8. Implementation Plan

### Phase 1: cc-connect instrumentation (Go) -- Priority

| Step | Description | Effort |
|------|-------------|--------|
| 1.1 | Add `prometheus/client_golang` dependency to cc-connect | 1h |
| 1.2 | Add `/metrics` HTTP handler on port `:9102` | 1h |
| 1.3 | Instrument Feishu HTTP client wrapper: counter, histogram, gauge for rate limit headers | 4h |
| 1.4 | Add tenant token refresh tracking (separate auth path) | 1h |
| 1.5 | Add feishu endpoint label derivation utility (parse path, strip IDs) | 1h |
| 1.6 | Add Prometheus scrape target in infra config | 30m |
| 1.7 | Add Grafana dashboard (Section 6) | 2h |

### Phase 2: Structured logging (rust CLI / shell)

| Step | Description | Effort |
|------|-------------|--------|
| 2.1 | Add rate limit event JSON logging to lark-cli HTTP wrapper | 2h |
| 2.2 | Add Vector `log2metric` transform to convert rate limit log events | 1h |
| 2.3 | Add textfile collector `.prom` output to healthcheck script | 1h |

### Phase 3: Alerting

| Step | Description | Effort |
|------|-------------|--------|
| 3.1 | Create alert rules (Section 7) in infra Prometheus | 1h |
| 3.2 | Configure alert routing to Feishu group (via webhook) | 30m |
| 3.3 | Add monthly quota burn projection panel | 1h |

### Phase 4: Testing and tuning

| Step | Description | Effort |
|------|-------------|--------|
| 4.1 | Deploy to staging, verify metrics appear | 1h |
| 4.2 | Tune bucket boundaries, label cardinality limits | 1h |
| 4.3 | Verify alert firing thresholds with synthetic 429s | 1h |
| 4.4 | Document rate limit response procedures in runbook | 1h |

### Estimated total effort: ~20h

---

## Appendix A: Feishu error codes (rate limit related)

| Code | Meaning | Response |
|------|---------|----------|
| `190004` | Method rate limit exceeded (per-endpoint QPS) | Retry with backoff after `Retry-After` header |
| `190005` | App rate limit exceeded (global app QPS) | Reduce overall call rate |
| `190006` | Concurrent requests limit exceeded | Serialize or batch requests |
| `99991400` | API frequency limit exceeded | General frequency control hit |
| `99991403` | Monthly quota exhausted | All calls blocked until next month |
| `99991404` | API QPS limit exceeded | Same as 190005 but at infrastructure level |

## Appendix B: Feishu API endpoint categories and typical limits

| Category | Typical QPS | Example endpoints |
|----------|-------------|-------------------|
| IM message | 5/chat | `/im/v1/messages`, `/im/v1/messages/:id/reply` |
| IM batch | 50k entries/day | `/im/v1/batch_message` |
| Bot info | 10 | `/bot/v3/info` |
| Auth | 75/hour | `/auth/v3/tenant_access_token/internal` |
| Calendar | 10 | `/calendar/v4/calendars`, `/calendar/v4/calendars/:id/events` |
| Doc/Docx | 20 | `/docx/v1/documents/:id` |
| Drive | 10 | `/drive/v1/files/:id` |
| Contact | 10 | `/contact/v3/users/:id` |
