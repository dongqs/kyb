# Session Summary v1: Full Observability Design (2026-05-23)

**Scope:** Complete architecture, technology selection, and design for kyb infra observability -- covering interception, collection, transport, storage, query, alerting, cost tracking, and security monitoring across all three clusters (Mac/Orbstack, Aliyun, Office nuc8).

**Documents produced in this session:** ~90 review documents + 5 design documents + 1 handbook + 1 standby config + 2 summary documents. Single source of truth: `docs/infra/reviews/recommended-stack.md`.

---

## 1. Architecture: Four-Layer Stack

```
INTERCEPTION       COLLECTION & ROUTING    TRANSPORT & BUFFER    STORAGE & QUERY
(docker events,    ├- Grafana Alloy         ├- Redpanda (Kafka)   ├- ClickHouse
 docker logs,      │  (recommended)         │  (single broker,   │  (single telemetry lake)
 OTel SDK,         ├- Vector + OTel         │   dev-container    ├- Grafana
 WS MITM proxy,    │  Collector             │   mode)            │  (CK datasource primary,
 Prometheus        │  (fallback)            │  Topics per        │   Prometheus for
 exporters)        └- Fluentd               │  service:          │   short-term alerts)
                                   (remote fallback)  │  cc.events         │
                                                       │  patrol.events     │
                                                       │  docker.events     │
                                                       │  otel.spans        │
                                                       └  hooks.events      ┘
```

---

## 2. Why Each Technology Was Chosen

### OTel SDK (OpenTelemetry)
**Role:** Instrumentation standard for traces from cc-connect (Go), patrol (Ruby), MCP proxy (Python).
**Why chosen:** Industry standard for distributed tracing. W3C TraceContext propagation. OTLP export to any backend. Single SDK per language handles span creation, context propagation, and export.
**Rejected:** Manual slog parsing (no trace context), log-based correlation (lossy two-table JOIN).

### Vector (Rust, timberio/vector)
**Role:** Log collection, parsing, enrichment, routing.
**Why chosen in the interim:** Single binary (~15 MB), 5-15 MB RSS idle, built-in ClickHouse sink, powerful VRL transform DSL, disk buffer, multi-cluster forward protocol. Beats Fluentd (80 MB, Ruby, community CK sink), beats Filebeat (no CK sink), beats Logstash (300-600 MB, JRuby).
**Phase out plan:** Replaced by Grafana Alloy after validation (Phase 2 of migration).

### Grafana Alloy
**Role:** Long-term unified collection agent (metrics + logs + traces).
**Why chosen over Vector + OTel Collector:** Single binary (~50 MB, 30-50 MB RAM), built-in Prometheus scraping, OTLP receiver, Docker discovery via labels, single config language (River). Replaces 3 agents (Vector, OTel Collector, Prometheus scraper) with 1.
**Status:** Recommended future state. Not deployed yet. Wait until Vector + existing pipelines are stable.

### Redpanda (Kafka API)
**Role:** Message bus / buffer between collectors and ClickHouse.
**Why chosen over Apache Kafka:** Single binary, no JVM, starts in ~2s vs 15-30s. At < 500 KB/day data volume, Kafka tuning is pure overhead. `--mode dev-container` optimizes for single-node no-Raft.
**Why Kafka at all:** CK downtime resilience (7-day buffer), replay capability, multiple consumer support, producer/consumer decoupling.
**Why not skip Kafka:** Without it, every producer has its own CK ingestion path. At current volume it works, but Kafka is worth the single-container cost (~256 MB RAM) for architectural cleanliness.
**Rejected alternatives:** NATS (no Kafka compat), Vector disk buffer only (single-consumer limitation).

### ClickHouse
**Role:** Single telemetry lake for logs, traces, metrics.
**Why chosen over alternatives:** Columnar storage is 100-1000x faster for log queries than PostgreSQL (row-oriented). Much simpler and lighter than Elasticsearch (1+ GB RAM). SQL interface.
**Why traces go to CK, not Tempo:** At < 1000 spans/day, a dedicated trace backend is wasteful. CK stores spans as flat rows with indexed `trace_id`. Grafana CK datasource can display trace waterfalls. Migrate to Tempo if span volume exceeds 1M/day (unlikely before 2027).

### Grafana
**Role:** Unified query and visualization layer.
**Why chosen:** Already deployed. CK datasource for all long-term queries. Prometheus datasource for real-time alerting. Community CK trace waterfall plugin for span visualization.

---

## 3. Key Architectural Decisions

### 3.1 Traces in ClickHouse, Not Tempo
The most contested decision. Resolution: CK-only until 1M spans/day. The ~100 MB fixed overhead of Tempo is not justified at 540 spans/day (~108 KB/day). CK enables native SQL joins between spans and logs in the same table.

### 3.2 Shared Envelope Schema
Every Kafka event uses the same JSON envelope: `{schema_version, source, event_type, event_time, producer, payload}`. This enables cross-source correlation without table joins and makes every topic queryable by the same pattern.

### 3.3 Vector -> Alloy Migration Path
Vector is deployed first (it works, it's well-understood). Alloy runs in parallel for evaluation. If Alloy proves stable (~week of dual-run), Vector is decommissioned. No lock-in risk.

### 3.4 Remote Clusters Keep HTTP-CK
Remote clusters (Aliyun, Office) continue their existing heartbeat curl loops and direct HTTP POST to central CK. Kafka is a Mac super-boss optimization. Remote clusters lack the volume to justify Kafka.

### 3.5 Two Direct-HTTP Legacy Paths
Boss heartbeats (1 event/60s) and claude_hook_events (~200 events/day) bypass Kafka and write directly to CK. Both are idempotent, low-volume, and non-critical. Kafka adds latency and complexity for zero benefit.

### 3.6 Grafana Provisioning as Code
Highest-ROI single action: Zero new infrastructure, complete reproducibility, version-controlled dashboards and alerts. Datasource YAMLs and deploy.sh already checked into `docs/infra/grafana/provisioning/`.

### 3.7 Cross-Service Trace Correlation
File-based services (patrol, docker-event-watcher, boss heartbeats) cannot propagate W3C TraceContext natively. Correlation is done via manual `correlation_id` attribute until all services are SDK-instrumented. Future state: W3C Baggage for automatic propagation.

---

## 4. Recommended Stack

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| Interception | Docker events watcher | Not deployed (P1) | Inside kyb-infra-boss |
| Interception | Docker stdout logs | Running (via Vector) | All containers |
| Interception | OTel SDK -> OTLP | Not deployed (P2) | cc-connect Go SDK first |
| Interception | WS MITM proxy | Optional, on-demand | feishu-proxy, <5% of sessions |
| Interception | Prometheus exporters | Not deployed (P1) | PG, Redis, Kafka, CK sidecars |
| Collection | Grafana Alloy | Not deployed (P0) | Long-term target |
| Collection | Vector | Running (interim) | Fallback until Alloy validated |
| Collection | OTel Collector | Not deployed (interim) | For traces if Alloy not ready |
| Transport | Redpanda | Not deployed (P0) | Single broker, dev-container |
| Storage | ClickHouse | Running | Central telemetry lake, Mac/Orbstack |
| Query | Grafana | Running | CK + Prometheus datasources |
| Buffer | Redpanda topics | Not deployed (P0) | 7-day retention per topic |
| Alerting | Prometheus + Alertmanager | Not deployed (P1) | Minimal: host-level first |
| Security scanning | Trivy | Not deployed (P0) | Daily scheduled scans |
| Config drift | kyb-config-snapshot.sh | Not deployed (P1) | SHA256 baseline checks |
| Cost tracking | token-tracker.sh | Not deployed (P0) | Claude Code token accounting |

### P0 Deployments (Do First)
1. Redpanda + topics + schema registry
2. Grafana Alloy (or validate Vector + OTel Collector interim)
3. Token cost tracking
4. Vulnerability scanning (Trivy)
5. Secret rotation monitoring

---

## 5. Complete Document Map

### 5.1 Core Architecture (Single Source of Truth)

| Document | File |
|----------|------|
| Recommended Stack (SSOT) | `docs/infra/reviews/recommended-stack.md` |
| Cost-Benefit Analysis | `docs/infra/reviews/observability-cost-benefit.md` |
| Cost-Security Summary | `docs/infra/reviews/summary-cost-security.md` |
| Interception Master Comparison | `docs/infra/reviews/intercept-comparison.md` |
| Storage Master Comparison | `docs/infra/reviews/storage-comparison.md` |
| Data Lineage Tracking | `docs/infra/reviews/data-lineage.md` |
| Observability Design (Chinese) | `docs/infra/observability-design.md` |

### 5.2 Technology Deep Dives

| Technology | Document |
|-----------|----------|
| Grafana Alloy | `docs/infra/reviews/grafana-alloy.md` |
| Unified Vector | `docs/infra/reviews/unified-vector.md` |
| Original Vector | `docs/infra/reviews/vector-pipeline.md` |
| Unified OTel | `docs/infra/reviews/unified-otel.md` |
| OTel + Vector Combined | `docs/infra/reviews/otel-vector.md` |
| Unified Kafka | `docs/infra/reviews/unified-kafka.md` |
| Original Kafka | `docs/infra/reviews/kafka-message-bus.md` |
| Fluentd Pipeline | `docs/infra/reviews/fluentd-pipeline.md` |
| Prometheus Scrape | `docs/infra/reviews/prometheus-scrape.md` |
| Cross-Cluster Metrics | `docs/infra/reviews/cross-cluster-metrics.md` |

### 5.3 Interception Approaches (13 designs)

| Approach | Document |
|----------|----------|
| MITM Proxy (feishu-proxy) | `reviews/proxy-intercept.md` |
| SOCKS5 Proxy | `reviews/socks5-intercept.md` |
| Sidecar Pattern | `reviews/sidecar-pattern.md`, `reviews/sidecar-intercept.md` |
| Docker Net Namespace | `reviews/docker-net-intercept.md` |
| HTTP Hooks Interception | `reviews/http-hook-intercept.md` |
| Stdout Parse (Log Scraping) | `reviews/stdout-parse.md` |
| Feishu Webhook Interception | `reviews/feishu-webhook-intercept.md` |
| eBPF Monitor | `reviews/ebpf-monitor.md` |
| eBPF + tcpdump Fallback | `reviews/ebpf-tcpdump.md` |
| Docker Events Watcher | `reviews/docker-events.md` |
| OTel cc-connect Instrumentation | `reviews/otel-cc-connect.md` |
| OTel Patrol Instrumentation | `reviews/otel-patrol.md` |
| OTel MCP Instrumentation | `reviews/otel-mcp.md` |

### 5.4 Monitoring & Alerting (25+ documents)

| Category | Documents |
|----------|-----------|
| Infrastructure | `crash-loop.md`, `service-dependency.md`, `container-network-latency.md`, `cross-container-traces.md`, `heartbeat-reliability.md`, `disk-growth.md`, `capacity-planning.md`, `cold-start-vs-resume.md` |
| Application | `session-monitor.md`, `token-efficiency.md`, `mention-response.md`, `message-classification.md`, `user-activity.md`, `tool-usage.md`, `session-duration.md` |
| Network | `tls-cert-monitor.md`, `image-pull.md`, `registry-latency.md`, `sing-box-metrics.md`, `kafka-lag.md`, `feishu-delivery.md`, `feishu-rate-limit.md` |
| Metrics | `cadvisor-metrics.md`, `node-exporter.md`, `ck-query-monitor.md`, `cross-cluster-metrics.md` |
| Incident Response | `incident-slo.md`, `error-budget.md`, `alert-fatigue.md`, `oncall.md`, `postmortem.md`, `incident-severity.md`, `self-diagnosis.md`, `chaos-engineering.md` |

### 5.5 Cost Tracking (7 documents)

| Document | File |
|----------|------|
| Token Cost | `docs/infra/reviews/token-cost.md` |
| Model Usage | `docs/infra/reviews/model-usage.md` |
| Cache Hit Ratio | `docs/infra/reviews/cache-hit.md` |
| Dangling Images | `docs/infra/reviews/dangling-images.md` |
| Volume Usage | `docs/infra/reviews/volume-usage.md` |
| Base Image Age | `docs/infra/reviews/base-image-age.md` |
| Cost Per Service | `docs/infra/reviews/cost-per-service.md` |

### 5.6 Security (6 documents)

| Document | File |
|----------|------|
| Secret Rotation | `docs/infra/reviews/secret-rotation.md` |
| Vulnerability Scan | `docs/infra/reviews/vuln-scan.md` |
| Network Compliance | `docs/infra/reviews/network-compliance.md` |
| Config Drift | `docs/infra/reviews/config-drift.md` |
| Multi-Tenancy | `docs/infra/reviews/multi-tenancy.md` |
| Config Audit | `docs/infra/reviews/config-audit.md` |

### 5.7 Bridge Design Documents

| Document | File |
|----------|------|
| Bridge CK Ingestion | `docs/infra/designs/bridge-ck-ingestion.md` |
| Bridge Hooks Alerting | `docs/infra/designs/bridge-hooks-alerting.md` |
| Bridge Metrics Logging | `docs/infra/designs/bridge-metrics-logging.md` |
| Issue Automation | `docs/infra/designs/issue-automation.md` |
| MCP Observability | `docs/infra/designs/mcp-observability.md` |

### 5.8 Grafana Provisioning

| File | Purpose |
|------|---------|
| `docs/infra/grafana/provisioning/datasources/clickhouse.yaml` | CK datasource |
| `docs/infra/grafana/provisioning/datasources/postgres.yaml` | PG datasource |
| `docs/infra/grafana/provisioning/datasources/prometheus.yaml` | Prom datasource |
| `docs/infra/grafana/provisioning/dashboards/dashboard_providers.yaml` | Dashboard provider |
| `docs/infra/reviews/grafana-provisioning.md` | Full design doc |
| `docs/infra/reviews/grafana-usage.md` | Usage review |

### 5.9 Agent Reviews (14 documents)

| Review | Files |
|--------|-------|
| Bridge CK Ingestion | `review-bridge-ck-ingestion-A1.md`, `A2.md`, `A3.md` |
| Bridge Hooks Alerting | `review-bridge-hooks-C1.md`, `C2.md`, `C3.md` |
| Bridge Metrics Logging | `review-bridge-metrics-B2.md`, `B3.md` |
| Issue Automation | `review-issue-automation-E1.md`, `E2.md`, `E3.md` |
| MCP Observability | `review-mcp-D1.md`, `D2.md`, `D3.md` |
| PG Replication | `review-pg-replication.md` |

### 5.10 Standby & Handbook

| File | Purpose |
|------|---------|
| `docs/infra/standby/cc-hooks-ready.md` | cc hooks direct-CK standby config |
| `docs/infra/standby/vector-ready.md` | Vector pipeline ready marker |
| `docs/infra/handbook/hooks-ck-pipeline.md` | Hooks-to-CK pipeline handbook |
| `docs/infra/handbook/registry-cache-deploy.md` | Registry cache deploy handbook |

---

## 6. Migration Phases

### Phase 0: Foundation (Week 1) -- Running
- [x] ClickHouse running on Mac/Orbstack
- [x] Grafana running on Mac/Orbstack
- [x] Vector parsing cc-connect logs to `cc.message_log`
- [x] Boss heartbeats via shell loop
- [x] Boss claude_hook_events via emit-ck.sh

### Phase 1: Buffer & Reliability (Week 1-2) -- P0
- [ ] Deploy Redpanda (`kyb-infra-redpanda`)
- [ ] Create topics: `cc.events`, `patrol.events`, `otel.spans`, `docker.events`
- [ ] Add Kafka sink to Vector (dual-write: CK + Kafka)
- [ ] Create CK Kafka Engine tables + MVs
- [ ] Verify row counts match; remove Vector direct CK sink
- [ ] Deploy docker-event-watcher inside boss

### Phase 2: Unify Collection (Week 2-3)
- [ ] Deploy Grafana Alloy on Mac/Orbstack
- [ ] Configure Alloy: docker_logs, Prometheus scrape, OTLP receive
- [ ] Migrate Vector configs to Alloy River syntax
- [ ] Remove Vector; Alloy primary collector
- [ ] Add OTel SDK to cc-connect

### Phase 3: Metrics & Tracing (Week 3-4)
- [ ] Deploy Prometheus exporters: PG, Redis, Kafka, CK, Node
- [ ] Configure Alloy to scrape all exporters
- [ ] Configure Prometheus remote write -> ClickHouse
- [ ] Add trace_id correlation to cc-connect logs

### Phase 4: Remote Clusters (Week 4-5)
- [ ] Deploy Fluentd (or Alloy) on Aliyun + Office
- [ ] Configure log shipping over Tailscale to central Kafka
- [ ] Deploy docker-event-watcher on remote bosses

### Phase 5: Grafana Dashboards (Ongoing)
- [ ] Infra Overview
- [ ] cc-connect Messages (throughput, latency, tokens)
- [ ] Patrol Health (heartbeat timeline, anomaly count)
- [ ] Docker Events (crash loop detection, OOM watch)
- [ ] Trace Explorer (waterfall via CK datasource)
- [ ] Token Cost (input/output per session)

### Cost & Security Parallel Track

| Priority | Item | Effort |
|----------|------|--------|
| P0 | Deploy token-tracker.sh | ~2h |
| P0 | Deploy Trivy scanning | ~2h |
| P0 | Deploy secret-rotation-exporter | ~2h |
| P1 | Deploy kyb-config-snapshot.sh | ~1h |
| P1 | Deploy kyb-net-monitor | ~2h |

---

## 7. Key Numbers

| Metric | Value |
|--------|-------|
| Documents produced | ~90 review + 5 design + 1 handbook + 1 standby + 2 summary |
| Design approaches compared | 13 interception, 7 storage, 8 full-stack |
| Total CK storage estimate (90d) | ~150-500 MB (without/with healthchecks) |
| Total new RAM estimate | ~400 MB (Redpanda 256M + Alloy 50M + exporters ~100M) |
| New containers | Redpanda (1) + Alloy (1) + exporters (3-5) |
| Full Prometheus stack RAM | ~860 MB (8 containers: Prometheus + Alertmanager + cadvisor x3 + exporters) |
| Current data volume | ~90 messages/day, ~500 KB/day |
| Estimated maintenance | ~1-2 hours/week |
| Total implementation effort | ~4-5 weeks calendar, ~30h actual work |
| Highest-ROI single action | Grafana provisioning as code (0 MB RAM, ~2h setup) |
| Highest-ROI infrastructure | Vector pipeline (64 MB RAM, solves data loss) |

---

## 8. Rejected Alternatives Summary

| Approach | Reason | Relevant Docs |
|----------|--------|---------------|
| Apache Kafka | JVM-based, heavy, slow start, overkill for ~500 KB/day | `kafka-message-bus.md`, `unified-kafka.md` |
| Grafana Tempo | Second storage backend, ~100 MB overhead for 108 KB/day data | `otel-kafka.md`, `unified-otel.md` |
| Fluentd as primary | Higher memory (80 MB vs 15 MB), community CK sink, weaker than Alloy | `fluentd-pipeline.md`, `unified-vector.md` |
| Elasticsearch | Heavy (1+ GB RAM), schema-on-write, slow bulk ingest vs CK | `storage-comparison.md` |
| NATS | No Kafka API compatibility | `kafka-message-bus.md` |
| Jaeger | Unmaintained (archived) | `otel-kafka.md` |
| eBPF for interception | Kernel 5.3+, fragile, overkill for ~540 frames/day | `ebpf-monitor.md`, `ebpf-tcpdump.md` |
| tcpdump for WS capture | TLS 1.3 renders PCAP opaque | `proxy-intercept.md` |
| Filebeat | No ClickHouse sink, limited transforms | `sidecar-pattern.md` |
| Logstash | 300-600 MB RAM, JRuby, overkill | `sidecar-pattern.md` |
| Per-service sidecar Vector | ~225 MB total for 15 sidecars vs ~50 MB for single Alloy | `sidecar-pattern.md` |
| Mimir/VictoriaMetrics | Extra backends; CK is already our long-term store | `sidecar-pattern.md` |

---

## 9. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Single unified collector | Alloy (future), Vector (interim) | Replace 3 agents with 1, all telemetry types |
| Trace storage | ClickHouse (not Tempo) | 540 spans/day; Tempo ~100 MB overhead unjustified |
| Message bus | Redpanda (not Apache Kafka) | No JVM, 2s startup, single binary |
| Schema registry | Apicurio (not Confluent SR) | In-memory mode, no PG/Kafka dependency |
| Envelope format | Shared JSON (not Protobuf/Avro) | Simpler at current volume, no code gen |
| Remote clusters | Keep HTTP-CK (not Kafka) | Insufficient volume to justify Kafka on remote |
| Kafka bypass | Heartbeats + hooks direct to CK | Idempotent, low-volume, non-critical |
| Container log source | File tail (not docker_logs API) | More reliable, survives Docker API issues |
| Log persistence | Unified `infra.message_log` canonical table | Single table, MVs for specialized views |
| Cross-service traces | `correlation_id` attribute | Shell services can't propagate TraceContext |
| Sampling strategy | 100% all services except healthcheck (10%) | Tiny volume; no sampling needed |
| Remote forwarding | OTel Collector agent over Tailscale | Centralized management, easy to add processors |
| Heartbeat replacement | Keep shell loop + direct CK (not migrated) | 1 event/60s, idempotent, works fine |
| Claude hooks path | keep emit-ck.sh direct HTTP (Kafka Phase 2) | 200 events/day, fail-open, low priority |

---

> **Bottom line:** One collector (Alloy), one message bus (Redpanda), one storage engine (ClickHouse), one query layer (Grafana). All telemetry flows service -> Alloy -> Kafka -> CK -> Grafana in a straight line, with two direct-HTTP legacy paths for low-volume heartbeats and hooks. The entire observability stack runs in ~400 MB RAM, ~150 MB/90d disk. Implementation is 4-5 weeks phased, starting with Redpanda + Alloy deployment.

> ／人◕ ‿‿ ◕人＼
