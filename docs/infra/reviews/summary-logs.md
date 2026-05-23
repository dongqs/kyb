---
decision: 现在就做
---

# Summary: Log Collection Across Infra Reviews

**Author:** boss
**Date:** 2026-05-23
**Scope:** Consolidated analysis of all `docs/infra/reviews/*` files along the "Logs" dimension. Which systems have log collection designs, which do not, and what to do about it.

---

## 1. What Was Reviewed

All 80+ files under `docs/infra/reviews/` were analyzed. The most relevant files:

| File | Log Relevance |
|------|--------------|
| `vector-pipeline.md` | Core: Unified Vector-based log shipping for all infra containers |
| `fluentd-pipeline.md` | Core: Fluentd as alternative collector for remote clusters |
| `grafana-alloy.md` | Core: Alloy as unified metrics/logs/traces collector |
| `otel-kafka-vector.md` | Core: OTel -> Kafka -> Vector -> CK pipeline |
| `otel-vector.md` | Core: OTel Collector + Vector combined pipeline |
| `unified-otel.md` | Core: Single OTel pipeline for all services |
| `unified-kafka.md` | Core: Kafka bus for ALL infra events with schema registry |
| `kafka-message-bus.md` | Original Kafka bus for observability events |
| `otel-kafka.md` | Span events as Kafka messages |
| `otel-cc-connect.md` | cc-connect OTel trace span model |
| `otel-patrol.md` | Patrol OTel trace spans |
| `otel-mcp.md` | MCP OTel trace spans |
| `otel-proxy.md` | OTel-enriched MITM proxy for WS frames |
| `otel-sidecar.md` | Per-container OTel Collector sidecar pattern |
| `sidecar-pattern.md` | General sidecar pattern for log/metric/trace shipping |
| `claude-telemetry.md` | Claude agent telemetry (tengu events) |
| `session-monitor.md` | cc-connect session file monitoring |
| `docker-events.md` | Docker container lifecycle event monitoring |
| `cross-container-traces.md` | Cross-container trace context propagation |
| `review-bridge-ck-ingestion-A*.md` | Reviews of cc-connect log pipeline assumptions |
| `review-bridge-hooks-C*.md` | Reviews of hook-based alerting pipeline |

---

## 2. Systems WITH Log Collection Designs

### 2.1 cc-connect (bridge)

**Log source:** Docker container stdout (`kyb-infra-cc-connect`)
**Format:** Go `slog` key=value (NOT JSON)

**Designed pipelines:**

| Pipeline | Collector | Transport | Storage | Status |
|----------|-----------|-----------|---------|--------|
| Message logs | Vector | Docker socket -> parse_kv -> enrich | `cc.message_log` (CK) | Designed, NOT deployed |
| OTel traces | OTel Collector | OTLP gRPC -> Collector | Tempo + CK (`otel_spans`) | Designed, NOT deployed |
| WS frames (proxy) | OTel proxy binary | OTLP gRPC -> Collector | Tempo + CK | Designed, NOT deployed |
| Session files | Script -> Vector | JSONL -> Vector | `cc.session_snapshots` (CK) | Designed, NOT deployed |

**Key findings from reviews (A1, A2, A3):**
- Log format is Go `slog` key=value, not JSON. Vector needs key=value parser, not `json_parser`.
- msg_id-based join required to consolidate "message received" and "turn complete" events.
- `turn_duration` is a Go duration string (e.g., `4h13m27.227059634s`) that must be parsed to seconds.
- Fields `chat_type`, `sender_type`, `message_type`, `content_text`, `trace_id` not available in INFO logs.

### 2.2 Boss (Claude hooks)

**Log source:** Claude Code hook events via emit-ck.sh
**Format:** JSON via HTTP POST

| Pipeline | Collector | Transport | Storage | Status |
|----------|-----------|-----------|---------|--------|
| Hook events | emit-ck.sh (shell) | HTTP POST -> CK | `kyb.claude_hook_events` | **Running** (~4,800 events/day) |
| Hook events (migrated) | emit-ck.sh -> kcat | Kafka `hooks.events` -> CK | same table | Designed, NOT deployed |
| Agent logs | Vector (docker_logs) | Docker socket -> filter -> enrich | `boss.agent_log` (CK) | Designed, NOT deployed |

**Key:** The Claude hook pipeline is the ONLY log pipeline partially running in production. It lacks buffering, retry, and replay.

### 2.3 Boss (heartbeats)

**Source:** Shell loop inside each `kyb-infra-boss`
**Storage:** `boss_heartbeats` (CK)
**Status:** Running. No retry, no buffer.

### 2.4 Patrol

**Source:** Patrol agents (shell)
**Current:** Logs to `.kyb-diaries/*.md` files only -- not shipped anywhere.
**Designed:** Vector -> CK (`patrol.health_checks`) and OTel file JSONL -> Collector.
**Status:** NOT deployed.

### 2.5 MCP (future)

**Pipeline:** JSON stdout -> Vector -> CK (`mcp.request_log`). OTel via proxy sidecar.
**Status:** No servers deployed. Design complete.

### 2.6 Docker Events

**Pipeline:** docker-event-watcher -> HTTP POST -> `infra.docker_events` (CK), or Kafka alternative.
**Status:** Design only. ~50 events/day (no HEALTHCHECK), ~46K/day (with HEALTHCHECK).

### 2.7 Claude Telemetry (tengu events)

**Pipeline:** `tengu-emit` -> JSONL -> Vector -> CK (`tengu_tool_use`, `tengu_session`, `tengu_error`)
**Status:** NOT deployed. ~8,000 events/day estimated.

### 2.8 Sing-Box (network metrics)

**Pipeline:** sb-metrics-poller -> HTTP POST or Kafka -> CK (`net.*`)
**Scope:** Connection metrics only. No runtime log collection.
**Status:** Poller may be running.

### 2.9 Kafka as Unified Event Bus (3 variants)

| Variant | Path | Status |
|---------|------|--------|
| `kafka-message-bus.md` | Producers -> Kafka -> CK Kafka Engine | NOT deployed |
| `unified-kafka.md` | ALL producers -> Kafka, Apicurio schema registry | NOT deployed |
| `otel-kafka-vector.md` | OTel Collector -> Kafka -> Vector -> CK | NOT deployed |

### 2.10 Vector Unified Pipeline

**Scope:** All infra containers via Docker label `kyb.logs=true`
**Status:** **Vector NOT deployed on any host** (confirmed by review A2).

### 2.11 Fluentd Alternative

**Scope:** All containers, recommended hybrid (Fluentd remote + Vector central).
**Status:** NOT deployed.

### 2.12 Grafana Alloy

**Scope:** Unified metrics/logs/traces collector per cluster.
**Status:** NOT deployed. Proposed Vector replacement.

### 2.13 OTel Sidecar Pattern

**Scope:** Per-container vs. per-host OTel Collector.
**Status:** Design only.

---

## 3. Systems WITHOUT Log Collection (Gaps)

| System | Impact | Severity |
|--------|--------|----------|
| **PostgreSQL x4** | PG errors, replication lag, connection exhaustion invisible | **P1** |
| **Redis** | OOM warnings, persistence info, connection limits invisible | **P1** |
| **Kafka / Redpanda** | Broker errors, partition changes, rebalancing issues invisible | **P1** |
| **ClickHouse** | Startup errors, merge failures, config reload issues invisible | **P2** |
| **Grafana** | Plugin load errors, datasource connectivity failures invisible | **P2** |
| **Registry cache** | Pull errors, disk/GC issues invisible | **P3** |
| **Sandbox agents** | Intentionally excluded (ephemeral, use `kyb exec`) | N/A |
| **Remote cluster infra** | Only heartbeats flow from Aliyun/Office | **P2** |

---

## 4. Cross-Cutting Gaps

### 4.1 No Unified Pipeline is Deployed

Despite 10+ design documents, **no log collection pipeline is operational** except boss heartbeats and Claude hook events (both ad-hoc HTTP POST).

From review A2:
- Vector binary: not installed on any host
- Vector container: not running
- Vector config: not created
- `cc` database and `cc.message_log` table: not created
- OTel Collector: not running

### 4.2 Collector Proliferation (No Standard)

At least 5 collectors proposed: Vector, Fluentd, Grafana Alloy, OTel Collector, direct HTTP POST. No standard chosen. This is blocking implementation.

### 4.3 No Log Health Monitoring

- No alerts for log pipeline failure (collector down).
- No log freshness checks.
- No self-observability for any log pipeline.

### 4.4 No Trace Collection Deployed

OTel designs detailed but not implemented:
- No OTel Collector container running
- No Tempo instance
- No `otel_spans` / `otel_logs` tables
- Cross-container trace propagation is pure design

### 4.5 No Log Rotation Management

All containers use Docker `json-file` with default settings (no max-size, no max-file).

### 4.6 No Multi-Cluster Log Shipping

Remote clusters (Aliyun, Office) have no log collector. Only boss heartbeats flow to central CK.

---

## 5. Recommendations

### P0 -- Deploy a Single Log Collector (Vector)

Pick Vector (most mature design, best CK sink, already detailed in vector-pipeline.md):
1. Create CK tables for cc-connect, patrol, boss, docker events.
2. Deploy Vector on Mac/Orbstack with Docker label `kyb.logs=true` discovery.
3. Implement the cc-connect key=value parser and msg_id join transform.
4. Verify end-to-end before adding remote clusters.

### P1 -- Collect DB/Infra Container Logs

Add log collection for PG, Redis, Kafka, ClickHouse, Grafana.
- Filter PG logs to ERROR/WARNING/PANIC only.
- Ship startup errors, crash logs, config warnings.

### P1 -- Add Log Health Monitoring

For every deployed pipeline:
- "Last event received" freshness check (alert if >10 min silence during active hours).
- Pipeline error counter.
- Buffer utilization gauge.

### P1 -- Migrate HTTP POST Pipelines to Vector

Replace all direct CK HTTP POST with Vector to gain buffering, retry, and replay.

### P2 -- Consolidate Collector Standard

- Keep Vector for logs.
- Add OTel Collector for traces only (when ready).
- Drop Fluentd (test Vector forward first).
- Re-evaluate Alloy in 6 months.

### P2 -- Multi-Cluster Log Shipping

Deploy Vector on Aliyun and Office after central pipeline is proven.

### P3 -- Implement Trace Collection

Deploy OTel Collector + OTEL tables + instrument cc-connect.

### Never -- Collect Sandbox Agent Logs

Intentionally excluded.

---

## 6. Summary Table

| System | Log Design | Pipeline | Gap Severity |
|--------|-----------|----------|-------------|
| cc-connect message logs | Design only | Vector -> CK | P0 |
| cc-connect OTel traces | Design only | OTel Collector -> CK | P2 |
| Claude hook events | **Running** (ad-hoc) | emit-ck.sh -> CK HTTP | P0 (migrate) |
| Boss heartbeats | **Running** (ad-hoc) | shell loop -> CK HTTP | P1 (migrate) |
| Boss agent logs | Design only | Vector -> CK | P1 |
| Patrol health checks | Design only | Vector -> CK | P1 |
| Docker events | Design only | Script -> CK/Kafka | P1 |
| Claude telemetry (tengu) | Design only | Vector -> CK | P2 |
| PostgreSQL x4 | **No collection** | -- | P1 |
| Redis | **No collection** | -- | P1 |
| Kafka / Redpanda | **No collection** | -- | P1 |
| ClickHouse | Internal only | `system.query_log` | P2 |
| Grafana | **No collection** | -- | P2 |
| Sing-box | Partial (metrics) | Poller -> CK | P2 |
| Registry cache | **No collection** | -- | P3 |
| MCP servers (future) | Design complete | Vector/OTel -> CK | Future |
| Sandbox agents | Intentionally excluded | -- | N/A |
| Remote cluster infra | Heartbeats only | -- | P2 |

---

## 7. Open Questions

1. **Vector vs Alloy vs both?** Which collector standard do we commit to?
2. **Kafka or direct-to-CK?** The Kafka designs add complexity not justified at ~MB/day volume.
3. **Who builds it?** Review A2 states "<1 hour" to deploy Vector for cc-connect. Why has no one been dispatched?
4. **OTel now or later?** Trace collection adds value, but logs are prerequisite.

---

> /人◕ ‿‿ ◕人＼
