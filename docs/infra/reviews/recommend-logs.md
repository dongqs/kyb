---
decision: 稍后做
---

# Log Pipeline Recommendation

**Date:** 2026-05-23
**Status:** Single Recommendation
**Context:** After evaluating Vector, Fluentd, and direct ClickHouse ingestion across multiple reviews, this document consolidates findings into a single log pipeline recommendation for kyb infra.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Options Evaluated](#2-options-evaluated)
3. [Decision Matrix](#3-decision-matrix)
4. [Recommendation: Vector + Direct CK (Hybrid)](#4-recommendation-vector--direct-ck-hybrid)
5. [Pipeline Architecture](#5-pipeline-architecture)
6. [Exceptions and Edge Cases](#6-exceptions-and-edge-cases)
7. [What This Replaces](#7-what-this-replaces)
8. [Rationale Details](#8-rationale-details)
9. [Implementation Quick-Start](#9-implementation-quick-start)
10. [Related Design Documents](#10-related-design-documents)

---

## 1. Executive Summary

**Adopt Vector as the primary log pipeline, with direct ClickHouse ingestion from cc-connect hooks as a supplementary path.**

| Component | Chosen Approach | Rationale |
|-----------|----------------|-----------|
| **cc-connect logs** | Direct CK (native hooks) | Zero infrastructure, sub-500ms latency, cc-connect v1.3.2+ has built-in webhook retry |
| **All other container logs** | Vector (Docker log API -> parse -> CK) | Built-in CK sink, ~50MB / ~20MB RAM, proven multi-cluster, VRL transforms for all log formats |
| **Future metrics/traces** | Grafana Alloy (separate) | Alloy is a unified metrics+logs+traces collector, but Vector is more mature for log-only. Alloy complements, not replaces, Vector for logs. |

**Why not a single tool:**
- Fluentd: Heavier (Ruby runtime, 80-200MB RAM under load), community CK plugin, weaker performance. Not the right fit when Vector handles every log format we need.
- Direct-only: Only cc-connect has native hooks. PG, Redis, Kafka, patrol, MCP, and boss stdout all need a general log shipper.
- Alloy-only: Alloy's log pipeline (`loki.source.docker`) is newer and less battle-tested than Vector's `docker_logs` source. Phase 1 recommendation is Alloy for metrics only.

---

## 2. Options Evaluated

### 2.1 Vector (timberio/vector:0.42.0-alpine)

Rust-based log shipper. Single binary, ~50MB image, ~20-40MB RAM under load. Built-in ClickHouse sink. VRL transform language.

- **Reviewed in:** `vector-pipeline.md`, `otel-vector.md`, `unified-vector.md`
- **Strengths:** Built-in CK sink, low resource usage, hot-reload, `docker_logs` source with label auto-discovery, VRL transforms for all log formats (JSON, key=value, regex)
- **Weaknesses:** Vector-forward protocol for multi-cluster is less mature than Fluentd's. Does not collect metrics or traces.

### 2.2 Fluentd (fluent/fluentd:v1.18-debian-1)

Ruby-based log shipper. ~80MB image, ~80-200MB RAM under load. 1000+ community plugins. Battle-tested `forward` protocol.

- **Reviewed in:** `fluentd-pipeline.md`
- **Strengths:** Most mature forward protocol for multi-cluster, richest parser ecosystem, 10+ years of production use, Treaure Data/CNCF backing
- **Weaknesses:** Higher resource usage, ClickHouse sink is a community gem (not official), Ruby dependency, slower throughput (~50-100K vs ~500K-1M events/s)

### 2.3 Direct ClickHouse Ingestion

cc-connect native hooks POST directly to CK HTTP endpoint. No middleware.

- **Reviewed in:** `hooks-direct-ck.md`, `cc-hooks-direct-ck.md`, `review-bridge-ck-ingestion-A1.md`/`A2.md`/`A3.md`
- **Strengths:** Zero additional infrastructure, lowest latency (100-500ms), native event semantics (not reconstructed from log lines), built-in retry, aligns with existing Claude hooks pattern
- **Weaknesses:** Only works for cc-connect (no general log shipping), no buffering on CK outage, event loss on cc-connect crash, requires cc-connect v1.3.2+

### 2.4 Grafana Alloy (for logs)

Grafana's unified telemetry collector. Can collect logs via `loki.source.docker`. Single binary ~50MB, ~30-50MB RAM idle.

- **Reviewed in:** `grafana-alloy.md`
- **Strengths:** One agent for metrics + logs + traces, Docker label auto-discovery, Grafana-native
- **Weaknesses (for log-only):** Log pipeline is newer (loki.source.docker), log parsing/transform is less mature than Vector's VRL, ClickHouse log output requires OTel bridge (not direct)
- **Verdict for logs:** Not ready to replace Vector. Recommended for **metrics** pipeline (separate track).

---

## 3. Decision Matrix

| Requirement | Vector | Fluentd | Direct CK |
|-------------|--------|---------|-----------|
| **ClickHouse sink (built-in)** | Yes | No (community gem) | N/A (native) |
| **Multi-cluster forward** | Native protocol | Battle-tested `forward` | N/A (single-node) |
| **Resource usage (idle)** | ~5-15 MB RAM | ~40-80 MB RAM | Zero |
| **Resource usage (1K ev/s)** | ~20-40 MB RAM | ~120-200 MB RAM | Zero |
| **Throughput** | ~500K-1M ev/s | ~50-100K ev/s | N/A |
| **Go slog key=value parse** | VRL `parse_key_value` | regexp + key_value plugins | Native (cc-connect hooks) |
| **Go duration parse** | Custom VRL function | Ruby helper plugin | Native (Float64 from hooks) |
| **Docker log discovery** | Label-based auto | File tail / Docker driver | N/A |
| **Buffering on CK outage** | Disk buffer (configurable) | File buffer (built-in) | None (events lost) |
| **Hot-reload config** | `vector validate` + SIGHUP | SIGHUP (partial) | N/A |
| **Health monitoring** | Built-in /health + /metrics | monitor_agent plugin | N/A |
| **Log format scope** | All containers | All containers | cc-connect only |
| **Maturity** | 2019 (5+ years) | 2011 (15+ years) | Depends on cc-connect version |
| **Event semantics** | Reconstructed from log lines | Reconstructed from log lines | **Native event types** |

**Key insight from the matrix:** Vector and Direct CK are complementary, not competing. Direct CK gives you native event semantics for cc-connect (the most important log source). Vector covers everything else. Fluentd does not win on any single requirement for this infra's scale.

---

## 4. Recommendation: Vector + Direct CK (Hybrid)

### 4.1 The Recommendation

```
┌─────────────────────────────────────────────────────────────────────┐
│                        log ingestion strategy                        │
│                                                                      │
│  cc-connect ──────► Direct CK (native hooks)                        │
│                      url=http://host.orb.internal:8123               │
│                      table=cc.hook_events                            │
│                      retry=2 attempts, 500ms-5s backoff             │
│                                                                      │
│  All other infra containers:                                         │
│    PG, Redis, Kafka, Grafana, sing-box, patrol, MCP, boss stdout    │
│                      │                                               │
│                      ▼                                               │
│  Vector (kyb-infra-vector)                                          │
│    source: docker_logs (label auto-discovery)                       │
│    parse: VRL remap transforms (JSON, key=value, regex)             │
│    enrich: add cluster, host, container_name metadata               │
│    sink: ClickHouse (per-table routing)                             │
│    buffer: disk (100MB max, drop_newest when full)                  │
│                                                                      │
│  Both paths land in ClickHouse, queried via Grafana.                │
└─────────────────────────────────────────────────────────────────────┘
```

**This is NOT "both and" — this is "Vector for everything except cc-connect."** Direct CK is not a competing pipeline; it is a specialized optimization for the one container that has native hook support. For all other containers, Vector is the single log pipeline.

### 4.2 Why Not All-Vector for cc-connect

Vector **can** collect cc-connect logs (it was designed to), but direct CK is strictly better for cc-connect specifically:

| Aspect | Vector pipeline | Direct CK hooks |
|--------|----------------|-----------------|
| Events captured | Reconstructed from log lines | Native event types (message.received, response.complete, session.crashed) |
| Latency | 1-5s (log tail + parse + batch) | 100-500ms |
| Infrastructure | 1 extra container | None |
| Session crash detection | Log-based heuristic | Explicit session.crashed event |
| Active sessions | Not available from logs | Heartbeat event includes active_sessions |

The cc-connect use case is unique because it has a native hook mechanism. No other container does. The optimization is worth it because cc-connect logging is the most important telemetry source (it captures all user interaction with the system).

### 4.3 Why Not Fluentd

Fluentd is not recommended for this infra because:

1. **Resource overhead matters on remote clusters.** The Aliyun sim has 2GB RAM. Fluentd at 80-200MB RAM is a significant fraction. Vector at 20-40MB is not.

2. **ClickHouse sink is a community gem.** `fluent-plugin-clickhouse` is maintained by the community, not by Treasure Data. Vector's ClickHouse sink is maintained by DataDog and tested in production at scale.

3. **Every log format we need is supported by Vector.** Go slog key=value, JSON, regex, multiline — Vector's VRL handles all of them. Fluentd's richer plugin ecosystem is not needed here.

4. **Multi-cluster at our scale is 3 clusters.** Vector's native `vector` source/sink handles this fine. Fluentd's battle-tested `forward` protocol would matter at 30+ clusters, not 3.

5. **No existing Fluentd deployment.** Vector already has designed configs (`vector-pipeline.md`). Starting from scratch with Fluentd means redoing all that work with no concrete benefit.

### 6.4 Why Not Alloy for Logs (Yet)

Grafana Alloy is the right long-term evolution for unified telemetry (metrics + logs + traces), but:

1. Alloy's log pipeline (`loki.source.docker`) is newer and less mature than Vector's `docker_logs` source.
2. Alloy cannot write logs directly to ClickHouse — it needs an OTel bridge or Loki intermediary.
3. Vector is already designed, configs are written, and the pipeline is understood.
4. Alloy is strongly recommended for **metrics** (fills a real gap), but for logs, Vector stays.

When to revisit: When Alloy's `loki.write` can target ClickHouse natively (not via OTel bridge), and when we have a use case that justifies the migration cost.

---

## 5. Pipeline Architecture

### 5.1 Data Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Mac/Orbstack (Central)                            │
│                                                                          │
│  ┌──────────────┐                                                        │
│  │ cc-connect    │─── HTTP POST ──► http://host.orb.internal:8123       │
│  │ (native hooks)│    retry×2          ?query=INSERT INTO cc.hook_events│
│  └──────────────┘                    ┌─► FORMAT JSONEachRow              │
│                                       │                                  │
│  ┌──────────────┐                    │                                  │
│  │ PG, Redis,   │─── stdout ──► Vector ──► ClickHouse                   │
│  │ Kafka,       │    (docker_logs)   │      cc.hook_events              │
│  │ Grafana,     │                    │      cc.message_log (fallback)   │
│  │ sing-box,    │                    │      boss.agent_log              │
│  │ patrol, MCP, │                    │      patrol.health_checks        │
│  │ boss stdout  │                    │      mcp.request_log (future)    │
│  └──────────────┘                    │                                  │
│                                       │                                  │
│                                       ▼                                  │
│                                ┌──────────────┐                          │
│                                │  ClickHouse   │◄── Grafana              │
│                                │ (port 8123)   │──► dashboards           │
│                                └──────────────┘                          │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                        Remote Clusters (Aliyun / Office)                │
│                                                                          │
│  ┌──────────────┐                                                        │
│  │ cc-connect    │─── HTTP POST ──► http://100.104.244.99:8123          │
│  │ (native hooks)│    (Tailscale)     (central CK)                      │
│  └──────────────┘                                                        │
│                                                                          │
│  ┌──────────────┐                                                        │
│  │ All other     │─── stdout ──► Vector ──► ClickHouse                  │
│  │ containers    │    (docker_logs)   (http://100.104.244.99:8123)      │
│  └──────────────┘                    (Tailscale)                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 What Each Pipeline Covers

| Pipeline | Containers | Data | CK Table |
|----------|-----------|------|----------|
| Direct CK hooks | cc-connect | Native hook events (message.received, response.complete, session.crashed, heartbeat, etc.) | `cc.hook_events` |
| Vector docker_logs | PG, Redis, Kafka, Grafana, sing-box | stdout logs (JSON/key=value) | `container_logs` (or per-service) |
| Vector docker_logs | patrol | Structured health check lines | `patrol.health_checks` |
| Vector docker_logs | boss | Agent stdout, unstructured logs | `boss.agent_log` |
| Vector docker_logs | MCP (future) | JSON request/response logs | `mcp.request_log` |
| Heartbeat curl (existing) | boss | Heartbeat metrics (docker_running, disk, etc.) | `boss_heartbeats` (unchanged) |
| Claude hooks emit-ck.sh (existing) | boss | Hook events (PreToolUse, etc.) | `kyb.claude_hook_events` (unchanged) |

### 5.3 What Is NOT Collected

Pragmatic decision: **Not all logs are worth collecting.**

| Container | Decision | Rationale |
|-----------|----------|-----------|
| PG logs | Skip | Verbose, high volume, low signal. Collect errors only if needed via FILTER. |
| Redis logs | Skip | "Ready to accept connections" every reconnect has zero signal. |
| Kafka logs | Skip | Kafka logs are verbose Kafka-internals. Monitor offsets, not logs. |
| ClickHouse logs | Skip | CK self-logs are for CK debugging only. Monitor query performance via system tables instead. |

**When to revisit:** If a specific incident requires debugging a PG/Redis/Kafka issue and logs would have helped, add selective collection (ERROR level only, via Vector filter).

---

## 6. Exceptions and Edge Cases

### 6.1 When to Use Direct CK Instead of Vector

Direct CK hooks are the better choice when **all** of these conditions are met:

1. The application has a native hook/webhook mechanism (like cc-connect v1.3.2+)
2. The event schema is known and stable (not reconstructed from log lines)
3. Data volume is < 1000 events/day (trivial for CK HTTP endpoint)
4. CK is on the same machine or same reliable network

**Current scope:** Only cc-connect meets all conditions.

### 6.2 When to Revisit the Decision

| Condition | Action |
|-----------|--------|
| Data volume exceeds 10K events/day per container | Add disk buffer to Vector or scale CK |
| cc-connect loses native hooks in a future version | Fall back to Vector pipeline (stdout parsing) |
| Remote cluster has unreliable CK connectivity (>1h downtime/week) | Add Fluentd for forward protocol on that cluster |
| Grafana Alloy matures its log-to-CK pipeline | Re-evaluate Alloy as Vector replacement |
| Number of clusters exceeds 10 | Re-evaluate Fluentd's forward protocol for multi-cluster |

### 6.3 Buffering and Reliability

| Pipeline | CK Outage Behavior | Data Loss |
|----------|-------------------|-----------|
| Direct CK (cc-connect) | Log warning, drop event. No buffer. | Events during outage lost (~34 KB/day) |
| Vector (all others) | Disk buffer (100MB), retry, drop_newest when full | Zero loss for typical outages (<1h at current volume) |

The direct CK lack-of-buffer is acceptable because:
- cc-connect runs on the same machine as CK (or same Tailscale mesh)
- Data volume is ~34 KB/day — trivial to re-ingest from Docker logs if needed
- cc-connect's built-in retry (2 retries, 500ms-5s backoff) covers transient blips

---

## 7. What This Replaces

| Current Method | Replaced By | Timeline |
|----------------|-------------|----------|
| cc-connect stdout -> (nothing) | Direct CK hooks | Day 1 |
| Vector planned for cc-connect (stdout parsing) | **Canceled.** Use direct hooks instead. | Immediate |
| Ad-hoc `docker logs` for debugging | Vector docker_logs | Day 1 |
| Boss heartbeats (curl loop) | **Not replaced.** Keep as-is (see 6.3) | Stays |
| Claude hooks (emit-ck.sh) | **Not replaced.** Keep as-is | Stays |

---

## 8. Rationale Details

### 8.1 Why Vector Over Fluentd

At current scale (~3 clusters, <1000 events/day), both Vector and Fluentd would work. The tiebreaker is:

1. **ClickHouse sink quality.** Vector's is built-in, maintained by DataDog, tested at scale. Fluentd's is a community gem. For our primary log backend, this matters.

2. **Resource efficiency.** On remote clusters (Aliyun sim: 2GB RAM), Vector's 20-40MB RAM vs Fluentd's 80-200MB is meaningful. At idle, Vector uses 5-15MB vs Fluentd's 40-80MB.

3. **Config simplicity.** Vector TOML is simpler than Fluentd Ruby DSL for straightforward pipelines. Our log pipeline is straightforward (source -> parse -> enrich -> CK sink).

4. **Hot-reload.** Vector's `vector validate` + SIGHUP is reliable and safe. Fluentd's SIGHUP is partial.

The fluentd-pipeline.md review reached a similar conclusion: "Central cluster: Vector (direct to CK, lower overhead, simpler config)".

### 8.2 Why Direct CK Over Vector for cc-connect

The hooks-direct-ck.md review concluded: **"Direct pattern wins for the current scale"** — <100 messages/day, single CK instance on the same machine. Zero infrastructure benefit outweighs buffering loss for observability data.

Specific advantages:
- **Native event semantics**: `session.crashed` and `heartbeat` event types are impossible to reconstruct from stdout log lines
- **Sub-500ms latency**: vs Vector's 1-5s from log tail + parse + batch
- **Zero additional resources**: No Vector container CPU/memory/disk
- **Stable interface**: Hook API is versioned; stdout log format is not

### 8.3 Why Not All-Fluentd

The fluentd-pipeline.md review's hybrid recommendation (Vector on central, Fluentd on remote) was considered. It was rejected for a simpler single-standard approach because:

1. Running two log shippers (Vector + Fluentd) doubles operational surface area
2. The benefit of Fluentd's forward protocol is marginal at 3 clusters
3. Vector's `vector` source/sink handles 3 clusters reliably
4. Team only needs to learn one log pipeline (Vector + VRL)

### 8.4 Why Not All-Direct

Only cc-connect has native hooks. All other containers output stdout/stderr and need a general-purpose log shipper. There is no path to make PG, Redis, Kafka, Grafana, sing-box, patrol, or MCP directly POST to ClickHouse without application changes that are not worth making.

---

## 9. Implementation Quick-Start

### Phase 1: Direct CK hooks for cc-connect (Day 1)

```toml
# Add to cc-connect config.toml
[hooks.webhook]
enabled = true
url = "http://host.orb.internal:8123/?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow"
method = "POST"
timeout_ms = 5000

[hooks.webhook.retry]
max_retries = 2
backoff_base_ms = 500
backoff_max_ms = 5000
```

See full details: `docs/infra/reviews/hooks-direct-ck.md`

### Phase 2: Deploy Vector (Day 1-2)

```bash
docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /home/dev/vector/vector.toml:/etc/vector/vector.toml:ro \
  -v vector-data:/var/lib/vector \
  -e VECTOR_CLUSTER=mac-orbstack \
  -e HOSTNAME=infra-boss \
  timberio/vector:0.42.0-alpine
```

See full config: `docs/infra/reviews/vector-pipeline.md`

### Phase 3: Label containers (Day 2)

```bash
# Add kyb.logs=true label to each infra container
docker run -d --label kyb.logs=true --label kyb.service=<service> ...
```

### Phase 4: Remote clusters (Day 3)

Deploy Vector on Aliyun and Office, pointing to central CK via Tailscale.

---

## 10. Related Design Documents

| Document | Relevance |
|----------|-----------|
| `vector-pipeline.md` | Full Vector config, transforms, CK schemas |
| `hooks-direct-ck.md` | Direct CK hook design, event payloads, retry config |
| `fluentd-pipeline.md` | Fluentd evaluation (not recommended) |
| `grafana-alloy.md` | Unified telemetry collector (metrics track, not logs) |
| `cc-hooks-direct-ck.md` | cc-connect hook discovery |
| `otel-vector.md` | OTel + Vector integration |
| `review-bridge-ck-ingestion-A1.md` | CK schema review A1 |
| `review-bridge-ck-ingestion-A2.md` | CK schema review A2 |
| `review-bridge-ck-ingestion-A3.md` | CK schema review A3 |

---

> **Summary:** Deploy Vector as the single log pipeline for all infra containers, with direct CK hooks as an optimized path for cc-connect only. Vector handles all log formats (JSON, key=value, regex), enriches with cluster metadata, and writes to ClickHouse via built-in sink. Direct CK hooks give native event semantics for the most important telemetry source with zero infrastructure overhead. This is not a "both" architecture — it is "Vector for everything except the one container that has native hook support." Fluentd is not recommended due to higher resource usage and community-maintained CK sink. The hybrid approach minimizes operational surface area while maximizing event quality.

> ／人◕ ‿‿ ◕人＼
