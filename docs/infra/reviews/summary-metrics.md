---
decision: 现在就做
---

# Summary: Metrics Dimension Across Infra Reviews

**Date:** 2026-05-23
**Scope:** All `docs/infra/reviews/` files analyzed along the Metrics dimension
**Status:** Comprehensive gap analysis

---

## Table of Contents

1. [Systems With Metrics Designs](#1-systems-with-metrics-designs)
2. [Systems With Partial Metrics Coverage](#2-systems-with-partial-metrics-coverage)
3. [Systems Without Metrics Designs](#3-systems-without-metrics-designs)
4. [Architectural Conflict: Prometheus vs Alloy](#4-architectural-conflict-prometheus-vs-alloy)
5. [Cross-Cutting Gaps](#5-cross-cutting-gaps)
6. [Recommendations](#6-recommendations)

---

## 1. Systems With Metrics Designs

### 1.1 cc-connect (Bridge) Application Metrics

| Attribute | Detail |
|-----------|--------|
| **Design docs** | `prometheus-scrape.md` (Section 5), `review-bridge-metrics-B2.md`, `review-bridge-metrics-B3.md` |
| **Review docs** | B2 (type/format review), B3 (Grafana panel reusability review) |
| **Defined metrics** | `cc_messages_received_total` (Counter, label: chat_type), `cc_messages_processed_total` (Counter, label: status), `cc_messages_sent_total` (Counter, label: chat_type), `cc_turn_duration_seconds` (Histogram, buckets 0.05-300s), `cc_tokens_per_turn` (Histogram, label: direction), `cc_errors_total` (Counter, label: error_type), `cc_active_sessions` (Gauge), `cc_up` (Gauge) |
| **Instrumentation** | Ruby `prometheus-client` gem, embedded WEBrick on :9091 |
| **Implementation** | Not implemented |
| **B2 findings** | Histogram/Summary type ambiguity resolved; bucket boundaries documented |
| **B3 findings** | No Grafana panel taxonomy, no dashboard-as-code, no shared PromQL templates, no cross-service panel reuse plan |

### 1.2 Prometheus Scraping Infrastructure

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `prometheus-scrape.md` |
| **Architecture** | Single Prometheus instance on Mac/Orbstack, scrapes all targets (local + remote via Tailscale) |
| **Scrape targets** | cc-connect (:9091), cadvisor (:8080 all clusters), node_exporter (:9100 all clusters), PG exporters (:9187 x4), Redis (:9121), Kafka (:9308), ClickHouse (:9116), sing-box (:9091), Boss exporter (:9101) |
| **Estimated series** | ~1,210 total (within single-instance capacity) |
| **Retention** | 30d or 10GB |
| **Alertmanager** | Config designed, routes to Feishu via cc-connect webhook |
| **Alert rules** | 20+ rules covering cc-connect, host, container, boss, service, Prometheus self-health |
| **Implementation** | Not deployed. ClickHouse, Grafana running. Prometheus/Alertmanager containers not created. |
| **Migration plan** | 6 phases, 1-2 days total effort |

### 1.3 cAdvisor Container Resource Metrics

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `cadvisor-metrics.md` |
| **Metrics** | CPU (`container_cpu_usage_seconds_total`, throttle ratio), Memory (working set, RSS, cache, OOM events), Network (RX/TX bytes, packets, errors, drops), Disk (fs usage, read/write bytes, I/O ops) -- ~60+ key metrics from ~300 available |
| **Storage** | Hybrid: Prometheus (15d, real-time) + Vector->ClickHouse (90d raw, 365d hourly, 3yr daily) |
| **Dashboard** | "Container Resource Overview" with 5 rows (Fleet Overview, CPU, Memory, Network, Disk) |
| **Alert rules** | 8 rules: HighCPU, HighMemory, OOM, CPUThrottling, DiskFull, NetworkErrors, CAdvisorDown |
| **Implementation** | Not deployed |
| **Storage estimate** | ~3.9 GB ClickHouse (first 90d), ~225 MB Prometheus TSDB (15d) |

### 1.4 Node Exporter Host Metrics

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `node-exporter.md` |
| **Metrics** | CPU (utilization, iowait, load averages), Memory (total, available, swap), Disk (size, free, I/O), Network (throughput, errors, drops), System (conntrack, context switches, running/blocked processes) |
| **Collectors** | ~13 enabled, ~20 disabled (keeps ~300 time series) |
| **Dashboard** | "Orbstack Host" with 5 rows (CPU, Memory, Disk, Network, System Health) |
| **Alerts** | 7 rules: HighCPU, MemoryLow, DiskFull, DiskFillRate, NetworkErrors, ConntrackHigh |
| **Implementation** | Not deployed |
| **Integration** | Assumes Prometheus already running (conflict: Prometheus not yet deployed) |

### 1.5 Grafana Alloy Unified Collector

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `grafana-alloy.md` |
| **Architecture** | Single Alloy container per cluster, replaces Prometheus + Vector + OTel Collector |
| **Metrics pipeline** | `discovery.docker` -> `prometheus.scrape` -> `prometheus.relabel` -> `prometheus.remote_write` -> ClickHouse |
| **Logs pipeline** | Phase 1: forward to Vector; Phase 2: native Alloy pipeline |
| **Traces pipeline** | Future: OTLP receiver, disabled in config |
| **Heartbeat replacement** | Materialized View on Prometheus metrics replaces curl-to-CK loops |
| **Docker label strategy** | `telemetry=enabled` and `metrics-port=XXXX` labels drive auto-discovery |
| **Estimated series** | ~2,500 per cluster, ~7,500 total |
| **Implementation** | Approved for Phase 1, not deployed |
| **Dependency** | Requires ClickHouse Prometheus remote-write endpoint verification |
| **Verdict** | Approved with conditions (gate: CK Prometheus endpoint support) |

### 1.6 Grafana Provisioning as Code

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `grafana-provisioning.md` |
| **Current state** | Manual datasource config, empty dashboards/alerting directories. NOT reproducible. |
| **Target state** | Provisioning-as-Code via YAML files in `docs/infra/grafana/provisioning/` |
| **Dashboards defined** | Boss Overview (5 panels), Cluster Health (2 panels), Heartbeat Monitor (1 panel) -- all querying ClickHouse heartbeat data |
| **Alerting rules** | Heartbeat warnings/critical, Disk usage, cc-connect down (Grafana managed alerts) |
| **Notifier** | Feishu webhook (URL via env var, not in git) |
| **Deployment** | `deploy.sh` using `docker cp` + hot-reload API (interim), then bind-mount (long-term) |
| **Priority** | P0 -- "implement immediately" |
| **Implementation** | Not done. Directory structure not created. |

### 1.7 Sing-Box Proxy Traffic Metrics

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `sing-box-metrics.md` |
| **Metrics** | Connection log (per-connection: outbound, destination, bytes, duration), Outbound snapshots (cumulative bytes, active connections, speed), Latency probes (per-node RTT, alive status) |
| **Storage** | ClickHouse: `net.connection_log` (30d retention), `net.outbound_snapshot` (7d), `net.latency` (90d) |
| **Collection** | Vector (JSON log parsing) + Python poller (Clash API polling every 10-30s) |
| **Dashboards** | Outbound Traffic Overview (3 panels), Connection Detail (3 panels), Latency Heatmap (3 panels) |
| **Alerts** | 4 candidates: all nodes dead, high latency, zero connections, traffic anomaly |
| **Storage estimate** | ~11.3 MB/day raw, ~40-65 MB total after CK compression |
| **Implementation** | Not implemented. Requires Clash API enabled on sing-box. |

### 1.8 Session File Monitoring

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `session-monitor.md` |
| **Metrics** | Session count (active/stale/zombie/corrupted), Age distribution, Idle time distribution, File health (corruption, size) |
| **Collection** | Hybrid: bash script (patrol integration) + ClickHouse (Vector ingestion) |
| **Storage** | `cc.session_snapshots`, `cc.session_latest` (MV), `cc.session_events` |
| **Dashboards** | Session Overview, Session Activity, Session Detail, Session Health |
| **Alerts** | 7 rules: StaleSession, ZombieSession, SessionCountAnomaly, CorruptedSession, OversizedSession, NoSessionDir, SessionDirNotWritable |
| **Implementation** | Not implemented. Phase 1 (patrol script) estimated < 1h. |

### 1.9 Session Duration / Lifecycle

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `session-duration.md` |
| **Metrics** | Session states (8 states defined), Container provenance (cold vs resume), Session duration, Idle timeout rate, Dispatch tree depth, Task success rate |
| **Collection** | Kyb::Reporter extensions + in-container agent instrumentation + patroller integration |
| **Storage** | Extended `kyb.sessions` table (18+ columns) + new `kyb.session_events` table |
| **Dashboards** | Session Overview (8 panels) |
| **Alerts** | 5 rules: zero active sessions, high idle timeout, all sessions idle, cold start spike, dispatch depth anomaly |
| **Implementation** | Not implemented. 5-phase plan (3 agent-sessions estimated). |

### 1.10 Error Budget / SLO Tracking

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `error-budget.md` |
| **SLO tiers** | Tier-0 (99.99%): cc-connect. Tier-1 (99.9%): PG, CK, Redis, Kafka. Tier-2 (99.5%): Vector, sing-box, mirrors. Tier-3 (99.0%): Grafana, build runners. |
| **Service catalog** | 16 services + 4 composite SLOs covering user journeys |
| **Burn rate alerting** | MWMBR pattern: P0 (14x/1h), P1 (6x/6h), P2 (2x/3d), P3 (1x/30d) |
| **Budget metrics** | 5 Prometheus gauge metrics defined: `slo_error_budget_remaining_ratio`, `slo_error_budget_consumed_seconds`, `slo_error_budget_total_seconds`, `slo_compliance_30d`, `slo_burn_rate_current` |
| **Recording rules** | Defined in Appendix A |
| **Dashboards** | Error Budget Overview (4 panels), Per-Service Deep Dive, Cluster Comparison, Super-Boss view |
| **Alert fatigue** | MWMBR AND logic, planned maintenance silencing, daily P3 digest |
| **Implementation** | Design complete. Depends on Prometheus deployment. |

### 1.11 Model Usage Tracking

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `model-usage.md` |
| **Data source** | Existing `kyb.claude_hook_events` table (model field already being collected) |
| **Pricing table** | `kyb.model_pricing` ClickHouse table (7 entries, Sonnet $3/$15 per Mtok, Opus $15/$75, Haiku $0.80/$4, Flash $0.80/$4) |
| **Metrics** | Daily cost by model tier, Cost per agent, Session cost, Cost distribution, Model selection heatmap |
| **Dashboards** | 6 panels: Model Usage Overview, Agent Cost Breakdown, Session Cost Distribution, Model Selection Heatmap, Real-Time Session Cost, Model Routing Distribution |
| **Alerts** | 5 rules: daily cost spike, single session >$10, agent Opus >50%, patrol non-Haiku, unknown model |
| **Cost targets** | $640/mo total infra target, $1,250/mo alert threshold |
| **Implementation** | Raw data exists. Cost calculation and dashboards not implemented. Pricing table not created. |

### 1.12 Tool Usage Telemetry

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `tool-usage.md` |
| **Data source** | Existing `kyb.claude_hook_events` table |
| **Analysis** | 48h production analysis across 5 sessions, 8,681 events, 14 tools |
| **Key metrics** | Tool call frequency, error rates by tool, duration distributions (avg/P50/P95/P99), daily trends, per-session breakdown, tool combination analysis |
| **Status** | Data exists, analysis performed. No dedicated dashboard or alerting. |

### 1.13 Disk Growth Monitoring

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `disk-growth.md` |
| **Metrics** | Used bytes, available bytes, used percent (Float32), inode percent, docker overlay size, daily growth rate (linear regression), predicted exhaustion date |
| **Storage** | ClickHouse: `cluster_disk_metrics` (raw, 180d), `cluster_disk_daily_mv` (365d), `cluster_disk_exhaustion` (latest) |
| **Collection** | Bash script on each boss, every 5 minutes |
| **Prediction** | Linear regression over 14-30d window. Output: growth_per_day, days_until_full, exhaustion_date, confidence (R-squared based) |
| **Dashboards** | 5 panels: Current Usage, Usage Over Time, Daily Growth Rate, Exhaustion Countdown, Docker Overlay Size |
| **Alerts** | Cluster-specific thresholds: Warning (30d or abs bytes), Critical (7d or abs bytes). Hard cap at 95% used. |
| **Implementation** | Not implemented. 4-phase rollout plan. |

### 1.14 Heartbeat Reliability Scoring

| Attribute | Detail |
|-----------|--------|
| **Design doc** | `heartbeat-reliability.md` |
| **Metrics** | Composite reliability score (0-100) from: missed beats (50% weight), late beats (25%), sibling health (25%) |
| **Scoring tiers** | healthy (90-100), degraded (70-89), unstable (50-69), critical (0-49) |
| **Collection** | Enhanced JSONL journal file per agent + ClickHouse tables (`otel.heartbeat_log`, `otel.patrol_reliability`) |
| **Dashboards** | 4 panels: Score Overview, Component Breakdown, Missed/Late Heatmap, Tier Distribution |
| **Alerts** | 5 rules: ScoreCritical (<50), ScoreUnstable (<70), ScoreDropping (trend), ClusterUnstable, NoScoreData |
| **Implementation** | Draft design. Not implemented. |

---

## 2. Systems With Partial Metrics Coverage

| System | What exists | Gap |
|--------|-------------|-----|
| **Boss heartbeats** | Working curl-to-CK pipeline (60s interval). `boss_heartbeats` table with docker_running, docker_total, disk_used_pct, mem_used_pct, load_1m. | UInt8 for disk_pct (loses precision), no byte values, no growth trends. Being superseded by dedicated disk monitoring and Prometheus boss exporter. |
| **cc-hooks ClickHouse pipeline** | Working pipeline: Claude Code hooks -> emit-ck.sh -> CK `kyb.claude_hook_events`. Contains model, token_count, duration_ms, tool_name, session_id. | No dashboards, no cost calculation, no alerting on this data. |
| **cAdvisor baseline** | `cadvisor-metrics.md` was written as a review/design, but the earlier `prometheus-scrape.md` covers cAdvisor as a scrape target. | Duplicate design work. The cAdvisor doc is more detailed on ClickHouse schemas. The Prometheus doc is more detailed on deployment. |
| **Docker event monitoring** | Mentioned in `prometheus-scrape.md` Section 6.3 (Approach A: docker-events-exporter, Approach B: boss shell loop). | No dedicated design or implementation. |
| **OTel traces for cc-connect** | Detailed span schema in `otel-cc-connect.md`. Defines trace model (7 span types), context propagation, export pipeline. | Trace pipeline not implemented. No OTel Collector deployed. No Tempo/Jaeger. |

---

## 3. Systems Without Metrics Designs

The following review files describe operational concerns but have **no dedicated metrics design** (no defined metric names, no collection pipeline, no dashboard):

| File | Topic | Metrics gap |
|------|-------|-------------|
| `alert-fatigue.md` | Alert fatigue analysis | No metrics for alert volume, false positive rate, MTTA/MTTR |
| `backup-monitor.md` | Backup monitoring | No backup success/failure metrics, no age metrics |
| `base-image-age.md` | Base image freshness | No image age metrics, no build frequency metrics |
| `boss-decision-latency.md` | Boss decision timing | No decision latency metrics defined |
| `boss-lifecycle.md` | Boss container lifecycle | No lifecycle metrics (create/stop/rm counts) |
| `cache-hit.md` | Cache hit rates | No cache hit/miss metrics defined |
| `ci-flakiness.md` | CI flakiness | No CI pass/fail metrics, no flake rate |
| `ck-query-monitor.md` | ClickHouse query monitoring | No CK query metrics (latency, throughput, errors) |
| `claude-telemetry.md` | Claude API telemetry | No latency, error rate, token metrics beyond hooks |
| `config-drift.md` | Configuration drift | No config hash/changes metrics |
| `container-network-latency.md` | Network latency | No latency metrics between containers |
| `crash-loop.md` | Crash loop detection | No restart count metrics (covered partially by cadvisor) |
| `dangling-images.md` | Stale Docker images | No image count/size metrics, no cleanup metrics |
| `docker-events.md` | Docker event stream | No event metrics (create/destroy/start/stop counts) |
| `ebpf-monitor.md` | eBPF monitoring | Experimental, no metrics design |
| `exit-codes.md` | Process exit codes | No exit code distribution metrics |
| `feishu-delivery.md` | Feishu message delivery | No delivery success/failure metrics |
| `feishu-rate-limit.md` | Feishu API rate limiting | No rate limit hit metrics |
| `feishu-webhook-intercept.md` | Webhook interception | No webhook metrics |
| `fluentd-pipeline.md` | Fluentd log pipeline | No pipeline metrics (buffer size, delivery lag) |
| `git-ops.md` | GitOps workflow | No Git operation metrics |
| `hooks-direct-ck.md` | Hooks direct to CK | Mentioned in context but no metrics design |
| `hooks-kafka.md` | Hooks via Kafka | No Kafka topic metrics (message count, lag) |
| `image-pull.md` | Image pull performance | No pull duration metrics, no pull failure metrics |
| `incident-severity.md` | Incident severity definitions | No incident count/time-to-resolve metrics |
| `kafka-lag.md` | Kafka consumer lag | No consumer lag metrics (covered partially by prometheus-scrape Kafka exporter) |
| `kafka-message-bus.md` | Kafka as message bus | No message throughput/latency metrics |
| `mr-cycle-time.md` | MR cycle time | No cycle time metrics defined |
| `multi-tenancy.md` | Multi-tenancy | No per-tenant usage metrics |
| `network-compliance.md` | Network compliance | No compliance check metrics |
| `oncall.md` | On-call procedures | No on-call metrics (incident count, escalation rate) |
| `otel-kafka.md` | OTel + Kafka integration | Design doc; metrics not the focus |
| `otel-kafka-vector.md` | OTel + Kafka + Vector | Design doc; metrics not the focus |
| `otel-mcp.md` | OTel MCP bridge | Design doc; traces/mcp focus |
| `otel-patrol.md` | OTel patrol integration | Traces for patrol, not metrics |
| `otel-proxy.md` | OTel proxy | Design doc |
| `otel-sidecar.md` | OTel sidecar | Design doc |
| `otel-vector.md` | OTel + Vector | Design doc |
| `permission-latency.md` | Permission latency | No latency metrics defined |
| `postmortem.md` | Postmortem process | No postmortem metrics |
| `proxy-intercept.md` | Proxy interception | No proxy metrics |
| `proxy-kafka.md` | Proxy Kafka integration | No metrics |
| `registry-latency.md` | Registry latency | No latency metrics (image-pull covers this partially) |
| `secret-rotation.md` | Secret rotation | No rotation metrics (age, success/failure) |
| `sidecar-intercept.md` | Sidecar pattern | No sidecar metrics |
| `sidecar-pattern.md` | Sidecar pattern analysis | No metrics |
| `stale-branches.md` | Stale branch cleanup | No branch age/count metrics |
| `system-load.md` | System load | Covered by node_exporter |
| `token-cost.md` | Token cost | Covered by model-usage.md |
| `unified-kafka.md` | Unified Kafka architecture | Design doc, no metrics emphasis |
| `unified-otel.md` | Unified OTel architecture | Design doc, lays groundwork for metrics, logs, traces |
| `unified-vector.md` | Unified Vector pipeline | Design doc, log pipeline focus |
| `user-activity.md` | User activity | No activity metrics defined |
| `vector-pipeline.md` | Vector pipeline design | Design doc, pipeline focus |
| `volume-usage.md` | Docker volume disk usage | No volume metrics (partially covered by disk-growth.md) |
| `vuln-scan.md` | Vulnerability scanning | No vulnerability metrics (count, severity, age) |

---

## 4. Architectural Conflict: Prometheus vs Alloy

Two competing architectures exist for the metrics pipeline:

| Dimension | Prometheus-scrape.md | Grafana-alloy.md |
|-----------|---------------------|-------------------|
| **Core component** | Prometheus server + Alertmanager | Grafana Alloy (single binary) |
| **Metrics storage** | Prometheus TSDB (15-30d) + remote write to CK | Direct to ClickHouse (Prometheus remote-write protocol) |
| **Alerting** | Prometheus Alertmanager -> Feishu | Grafana managed alerts (future) |
| **Logs** | Out of scope (Vector handles) | Phase 1 forward to Vector, Phase 2 native |
| **Traces** | Out of scope | Future OTLP receiver (disabled) |
| **Discovery** | Static config per target | Docker label-based auto-discovery |
| **Agent count** | ~10 containers (Prometheus + 8 exporters + Alertmanager) | 1 per cluster |
| **Docker socket** | Not required | Required for discovery |
| **Config language** | YAML | River |
| **Status** | Older design, referenced by multiple docs | Newer design, approved for Phase 1 |
| **ClickHouse dependency** | Optional (remote write) | Required (primary backend) |
| **Gate** | None | CK Prometheus endpoint support |

**Assessment:** These two designs are siblings, not replacements. `prometheus-scrape.md` describes the conventional Prometheus-centric approach. `grafana-alloy.md` proposes a newer unified approach that subsumes Prometheus + Vector. However, Alloy was written after Prometheus-scrape and explicitly references it. The recommended path according to `grafana-alloy.md` Section 11 (P0 items) is to verify CK Prometheus endpoint support and decide -- if CK supports it, use Alloy direct; if not, deploy lightweight Prometheus as intermediary.

**Recommendation:** Resolve this conflict by:
1. Verifying CK Prometheus endpoint support (1-hour task)
2. If supported: adopt Alloy path, retire Prometheus-scrape design
3. If not supported: deploy lightweight Prometheus on Mac only, keep Alloy for remote clusters
4. Archive the non-chosen design with a pointer to the decision

---

## 5. Cross-Cutting Gaps

### 5.1 Implementation Gap

The single largest gap: **almost nothing is deployed**. Of 14 systems with complete metrics designs, **only the heartbeat pipeline and cc-hooks pipeline are running in production**. The rest are designs awaiting implementation:

| System | Designs | Implemented |
|--------|---------|-------------|
| Boss heartbeats (curl->CK) | Production | Yes |
| cc-hooks pipeline | Production | Yes |
| cc-connect app metrics | Complete | No |
| Prometheus server | Complete | No |
| cAdvisor | Complete | No |
| node_exporter | Complete | No |
| Grafana Alloy | Complete, approved | No |
| Grafana provisioning | P0 recommendation | No |
| Sing-box metrics | Complete | No |
| Session monitoring | Complete | No |
| Session lifecycle | Complete | No |
| Error budgets | Complete | No |
| Model usage | Partial | Partial (data collected) |
| Tool usage | Analysis only | Partial (data collected) |
| Disk growth | Complete | No |
| Heartbeat reliability | Draft | No |

### 5.2 Competing Designs

- **Prometheus-scrape.md vs Grafana-alloy.md**: Two different architectural approaches to metrics collection. Both describe the same system from different angles. The Alloy design explicitly subsumes the Prometheus role.
- **cadvisor-metrics.md vs prometheus-scrape.md Section 6**: Both describe cAdvisor deployment with overlap. The cadvisor doc has more CK schema detail but assumes Prometheus already exists.
- **Multiple Grafana dashboard designs**: `grafana-provisioning.md` designs 3 dashboards for heartbeats. `cadvisor-metrics.md` designs container dashboards. `error-budget.md` designs SLO dashboards. `session-duration.md` designs session dashboards. No unified dashboard catalog.

### 5.3 Alerting Gap

- No alerting pipeline exists (no Alertmanager, no Grafana alerts configured)
- Heartbeat reliability is checked only by patrol (5-min granularity, human-in-loop)
- No automated notification to Feishu for any metric condition
- Error budget alerting depends on Prometheus (not deployed)

### 5.4 Grafana Gap

- Grafana is running with manual ClickHouse datasource (not reproducible)
- **Zero dashboards deployed** despite detailed designs in 6+ documents
- No dashboard-as-code workflow
- Grafana version not pinned (uses `latest` tag)

### 5.5 Missing Metric Types

| Metric type | Coverage | Missing |
|-------------|----------|---------|
| Application metrics (cc-connect) | Designed, not implemented | - |
| Container resource metrics | Designed, not implemented | - |
| Host resource metrics | Designed, not implemented | - |
| Proxy traffic metrics | Designed, not implemented | - |
| Disk growth/prediction | Designed, not implemented | - |
| Session metrics | Designed, not implemented | - |
| Cost metrics (model usage) | Raw data exists | Dashboards, alerting |
| Error budgets / SLO | Designed | Depends on Prometheus |
| Heartbeat reliability | Draft | Implementation |
| CI/CD metrics | **No design** | CI pass/fail, flake rate |
| Database query performance | **Mentioned only** | PG, CK query metrics |
| Cache hit rates | **No design** | Registry cache, OSS cache |
| Network latency | **No design** | Cross-container, cross-cluster |
| Backup monitoring | **No design** | Success/failure, age |
| Security metrics | **No design** | Vulnerability counts, secret age |
| User activity | **No design** | Active users, session frequency |
| Kafka consumer lag | **No design** | (covered partially by Prometheus scrape target) |

---

## 6. Recommendations

### P0: Resolve Architectural Conflict

1. **Verify ClickHouse Prometheus endpoint** (1 hour). This gates the entire metrics architecture. Result determines Prometheus vs Alloy path.
2. **Deploy the chosen collector** (Alloy or Prometheus) on Mac/Orbstack within 1 day.
3. **Archive the unchosen design** with a decision record.

### P0: Implement Grafana Provisioning

4. **Create `docs/infra/grafana/provisioning/` directory structure** (30 min). Highest-leverage action because it makes the Grafana instance reproducible.
5. **Deploy the three heartbeat dashboards** from `grafana-provisioning.md` (Boss Overview, Cluster Health, Heartbeat Monitor). These use existing ClickHouse data and require no new infrastructure.

### P1: Deploy Core Metrics Pipeline

6. **Deploy cAdvisor** on Mac/Orbstack (1 hour). Provides immediate container-level CPU/memory/network visibility with zero application changes.
7. **Deploy the first Grafana dashboard** using cAdvisor data via the chosen Prometheus/Alloy pipeline. This closes the "zero dashboards" gap.
8. **Configure Alertmanager or Grafana alerting** with at least the critical alert rules (cc-connect down, disk full, container OOM).

### P1: Close the "Raw Data Without Dashboards" Gap

9. **Build model usage dashboard** (2 hours). Raw data exists in `kyb.claude_hook_events`. Cost calculation queries are documented in `model-usage.md` Section 6.
10. **Build tool usage dashboard** (1 hour). Same data source. Analysis patterns in `tool-usage.md`.

### P2: Implement Designed Systems

11. **Deploy node_exporter** on all clusters (1 hour). Host-level metrics are a prerequisite for meaningful capacity planning.
12. **Implement disk growth monitoring** (2 hours). Schema, collection script, and prediction are fully designed in `disk-growth.md`.
13. **Implement sing-box traffic metrics** (2 hours). Enables network cost attribution and latency monitoring.
14. **Implement session monitoring** (1 hour for patrol script). Script is ready to deploy.

### P2: Start Error Budget Tracking

15. **Deploy Prometheus recording rules** for SLO metrics once Prometheus/Alloy is running.
16. **Build Error Budget Overview dashboard**. Budget remaining and burn rate are the single most useful operational metrics.

### P3: Ongoing Metrics Infrastructure

17. **Create a dashboard catalog** mapping each data source to its dashboards, panels, and alert rules. Prevents the proliferation of orphan designs.
18. **Instrument remaining services** (Kafka consumer lag, database query performance, cache hit rates) as operational needs arise.
19. **Establish a metrics ownership process**: each service should have a designated owner for metric definitions and dashboard maintenance.
20. **Review and tune alert thresholds** after 2 weeks of baseline data collection.

---

## Appendix: Design Count by Implementation Status

| Status | Count | Systems |
|--------|-------|---------|
| **Production (working)** | 2 | Boss heartbeats, cc-hooks pipeline |
| **Design complete, not implemented** | 10 | cc-connect metrics, Prometheus, cAdvisor, node_exporter, Alloy, sing-box, session monitor, session lifecycle, error budget, disk growth |
| **Draft design** | 1 | Heartbeat reliability scoring |
| **Analysis exists, no dashboard** | 2 | Model usage, tool usage |
| **No metrics design** | 50+ | All other review files (see Section 3) |

---

> /人◕ ‿‿ ◕人＼
