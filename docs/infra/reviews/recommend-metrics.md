---
decision: 稍后做
---

# Recommend: Metrics Stack for kyb Infra

**Date:** 2026-05-23
**Status:** Single recommendation
**Scope:** What tool(s) should collect, transport, store, and alert on metrics across all kyb infra clusters (Mac/Orbstack, Aliyun, Office).

---

## Executive Summary

**Adopt Grafana Alloy as the unified metrics collector, writing Prometheus remote-write to ClickHouse, with Prometheus Alertmanager for alerting.**

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Scraping | Grafana Alloy (embedded Prometheus scraper) | One agent replaces three; Docker service discovery; Grafana-native |
| Storage | ClickHouse (Prometheus remote-write protocol) | Already running; single telemetry lake; no new backend |
| Alerting | Prometheus Alertmanager | Battle-tested; Feishu webhook integration; standard routing |
| Visualization | Grafana (ClickHouse datasource) | Already running; same tool as logs and traces |
| Service metrics | Prometheus exporters (cc-connect, cadvisor, node_exporter, PG, Redis, Kafka) | Industry standard; every service has one |

This is not a compromise between OTel, Prometheus, and Vector -- it is a recognition that **none of the three alone is sufficient**, and Alloy is the single binary that subsumes all their best parts.

---

## 1. The Three Contenders and Why None Alone Is Enough

### 1.1 Prometheus

**What it does well:** Scraping metrics endpoints, storing time series, evaluating alerting rules, providing PromQL for query. Battle-tested for a decade.

**What it cannot do:** Traces (no OTLP receiver), logs (no file tail or syslog), message routing/enrichment (no VRL). You need OTel Collector for traces, Vector or Fluentd for logs, and Alertmanager for alert routing. Three agents.

**Verdict for solo adoption:** Prometheus-only means spinning up Prometheus + OTel Collector + Vector. Three containers, three config formats (YAML + YAML + TOML), three restart/reload procedures.

### 1.2 OpenTelemetry Collector

**What it does well:** Receiver-native OTLP ingestion from SDK-instrumented services, protocol gateway (gRPC + HTTP), backpressure isolation, tail sampling, exporter to any backend.

**What it cannot do:** Scrape Prometheus metrics endpoints efficiently (its `prometheus` receiver is a receiver that accepts remote writes, not a scraper). Parse and transform log formats (no VRL, no Ruby DSL). Route events based on content (no route transform by signal type).

**Verdict for solo adoption:** OTel Collector alone cannot collect metrics from standard Prometheus exporters (cadvisor, node_exporter, PG exporter). It needs Prometheus or Alloy to scrape those endpoints and forward OTLP.

### 1.3 Vector

**What it does well:** Log parsing via VRL (powerful, typed DSL), multi-sink routing, disk-buffered delivery to ClickHouse, multi-cluster forwarding over Tailscale.

**What it cannot do:** Scrape Prometheus metrics (no `prometheus.scrape` source -- Vector is a log/event pipeline, not a metrics scraper). Receive OTLP traces natively (the `opentelemetry` source is relatively new and limited to gRPC, no HTTP/protobuf).

**Verdict for solo adoption:** Vector is excellent for logs but **cannot scrape metrics**. Metrics require Prometheus or Alloy alongside it.

### 1.4 What We Need vs. What Each Provides

| Capability | Prometheus | OTel Col. | Vector | Need it? |
|-----------|------------|-----------|--------|----------|
| Scrape :9091/metrics from cc-connect | Yes | Weak (no scraper) | No | Yes |
| Scrape cadvisor :8080 (all containers) | Yes | Weak | No | Yes |
| Scrape node_exporter :9100 (all clusters) | Yes | Weak | No | Yes |
| Scrape PG/Redis/Kafka exporters | Yes | Weak | No | Yes |
| Receive OTLP traces from SDK services | No | Yes | Limited | Yes (future) |
| Parse Go slog key=value logs | No | Weak (transform) | Yes (VRL) | Nice-to-have |
| Enrich with cluster/host metadata | No | Weak | Yes | Yes |
| Disk-buffer for CK downtime | No | Queue only | Yes (disk buffer) | Yes |
| Docker service discovery | No | No | No | Yes |
| Alert evaluation + routing | Partial | No | No | Yes |

**No single tool covers all needs. Alloy covers more than any two combined.**

---

## 2. Recommendation: Grafana Alloy

### 2.1 What Alloy Is

Grafana Alloy is a single binary (~50 MB) that embeds:

- **Prometheus scraper** (same code as Prometheus) for metrics endpoints
- **OTLP receiver** for traces from SDK-instrumented services
- **Loki receiver + filelog source** for container logs
- **Prometheus remote-write exporter** for sending to ClickHouse
- **Docker service discovery** via `discovery.docker`
- **River config language** (declarative blocks, similar to HCL)

Alloy runs as one container per cluster. It replaces the three-agent stack (Prometheus + OTel Collector + Vector) with a single agent.

### 2.2 Why Alloy (Not Another Agent)

**Vs. Prometheus + OTel Collector + Vector:**

| Factor | Alloy | Prometheus + OTel Col. + Vector |
|--------|-------|--------------------------------|
| Containers | 1 | 3 |
| Memory | 30-50 MB idle | 100-150 MB combined |
| Config formats | River (1 file) | YAML + YAML + TOML |
| SIGHUP reload | One command | Per-agent |
| Metrics scraping | Built-in (Prometheus embedded) | Prometheus only |
| Trace collection | Built-in (OTLP receiver) | OTel Collector |
| Log parsing | Built-in (Loki receiver + River) | Vector |
| Docker discovery | `discovery.docker` | Prometheus file_sd only |
| ClickHouse output | Built-in (remote-write) | Vector writes HTTP |

**Vs. keeping current ad-hoc state:**

Current state has NO metrics collection. Heartbeats (60s granularity, aggregate only) are the closest thing to metrics. There is no container CPU/mem/disk visibility, no cc-connect latency tracking, no cross-cluster resource comparison. The cost of this is blind operation: you don't know a container is OOM-killing until patrol catches it 5 minutes later.

### 2.3 Trade-Offs Acknowledged

| Concern | Mitigation |
|---------|-----------|
| River config language is new | Learnable in ~1 hour. The community is growing fast (Grafana Labs backing). |
| Alloy is newer than Prometheus | Alloy embeds the same Prometheus scrape code. The scraper is the same battle-tested code. |
| AGPLv3 license | Free for internal infrastructure use. Not embedding in a commercial product. |
| Another agent to manage | One agent replaces three. Net reduction. |
| ClickHouse Prometheus remote-write is less tested than native Prometheus TSDB | Grafana and ClickHouse have jointly developed the remote-write protocol. It works. |

---

## 3. Architecture: Metrics Pipeline

### 3.1 Data Flow

```
                   ┌─────────────────────────────────────┐
                   │     Each Cluster (Mac/Aliyun/Office) │
                   │                                     │
  ┌────────────┐   │  ┌────────────┐  ┌───────────────┐  │
  │ cc-connect │   │  │ Service    │  │ System        │  │
  │ :9091      │   │  │ exporters  │  │ (cadvisor,    │  │
  │ /metrics   │   │  │ (PG/Redis/ │  │  node_exp.)   │  │
  │            │   │  │  Kafka/CK) │  │  :8080/:9100  │  │
  └─────┬──────┘   │  └─────┬──────┘  └───────┬───────┘  │
        │          │        │                  │          │
        └──────────┼────────┼──────────────────┘          │
                   │        │          │                  │
                   ▼        ▼          ▼                  │
          ┌───────────────────────────────────────────┐   │
          │        Grafana Alloy (per cluster)         │   │
          │                                            │   │
          │  discovery.docker ──> prometheus.scrape    │   │
          │      (label-based auto-discovery)          │   │
          │                                            │   │
          │  ┌─────────────────────────────────────┐   │   │
          │  │  relabel: add cluster, service,     │   │   │
          │  │  drop unwanted series               │   │   │
          │  └──────────────┬──────────────────────┘   │   │
          │                 │                           │   │
          │  ┌──────────────▼──────────────────────┐   │   │
          │  │  prometheus.remote_write            │   │   │
          │  │  url = http://<ck>:8123/prometheus/ │   │   │
          │  │           write                     │   │   │
          │  └─────────────────────────────────────┘   │   │
          └────────────────────────────────────────────┘   │
                   │                                      │
                   │  Prometheus remote-write over        │
                   │  Tailscale (remote clusters)         │
                   │  or localhost (Mac/Orbstack)          │
                   ▼                                      │
          ┌──────────────────┐                            │
          │   ClickHouse     │                            │
          │   (Central CK)   │                            │
          │                  │                            │
          │  ┌──────────────┐│                            │
          │  │ Time-series  ││                            │
          │  │ tables       ││                            │
          │  │ (Prometheus  ││                            │
          │  │  remote-write││                            │
          │  │  format)     ││                            │
          │  └──────┬───────┘│                            │
          └─────────┼────────┘                            │
                    │                                     │
                    ▼                                     │
          ┌──────────────────┐                            │
          │    Grafana       │                            │
          │  (ClickHouse DS) │                            │
          │                  │                            │
          │  Dashboards:     │                            │
          │  - Infra Overview│                            │
          │  - cc-connect    │                            │
          │  - Cluster Health│                            │
          └──────────────────┘                            │
                                                          │
  ┌──────────────────────────────────────────────────────┐│
  │  Alertmanager (central, Mac/Orbstack)                ││
  │                                                      ││
  │  Evaluate rules → fire → Feishu webhook             ││
  │  Alert rules defined in Alloy River config           ││
  └──────────────────────────────────────────────────────┘│
```

### 3.2 Route from Remote Clusters

Remote clusters (Aliyun, Office) run their own Alloy instance. Instead of writing directly to CK (which requires opening CK to remote connections), they forward metrics via **Prometheus remote-write over Tailscale** to the central Alloy or directly to central CK:

- **Mac/Orbstack**: Alloy writes directly to `http://host.orb.internal:8123/prometheus/write`
- **Aliyun**: Alloy writes to `http://100.104.244.99:8123/prometheus/write` (Tailscale)
- **Office**: Alloy writes to `http://100.98.29.39:8123/prometheus/write` (Tailscale, relay)

This keeps CK listening on only one interface and avoids per-cluster firewall rules.

### 3.3 What Gets Scraped

| Target | Port | Path | Interval | Source of config |
|--------|------|------|----------|-----------------|
| cc-connect | 9091 | /metrics | 15s | `prometheus.scrape` static target |
| cAdvisor (per cluster) | 8080 | /metrics | 30s | `discovery.docker` + label filter |
| node_exporter (per cluster) | 9100 | /metrics | 30s | Static target (per cluster Tailscale IP) |
| PG exporter (x4 versions) | 9187 | /metrics | 30s | Static target |
| Redis exporter | 9121 | /metrics | 30s | Static target |
| Kafka exporter | 9308 | /metrics | 30s | Static target |
| ClickHouse native | 8123 | /metrics | 30s | Static target |
| Boss exporter | 9101 | /metrics | 30s | Static target |
| sing-box | 9091 | /metrics | 30s | Static target |

~1,210 time series total (estimated, see `prometheus-scrape.md`). Well within single-instance capacity.

### 3.4 Exporter Deployments

All exporters are documented in `prometheus-scrape.md` sections 3.2.1-3.2.5 and 6-7. Key points:

- **cc-connect**: Embedded Prometheus client in the Ruby process (port 9091). No sidecar needed.
- **cAdvisor**: One per cluster host (Docker container, privileged). Covers all containers.
- **node_exporter**: On Mac via Homebrew (native macOS), on Linux hosts via Docker (network=host).
- **Service exporters**: One sidecar per data service (PG/Redis/Kafka/CK), joining `kyb-net`.

---

## 4. Why Not the Alternatives

### 4.1 Why Not Standalone Prometheus

Prometheus is the obvious choice -- it is the metric. But:

- Prometheus is **metrics-only**. You still need OTel Collector for traces and something (Vector/Fluentd) for logs. That is three agents.
- Alloy **embeds the same Prometheus scrape code**. You lose nothing on the scraping side by using Alloy.
- Prometheus's local TSDB is ephemeral (data lost on container restart without persistent volume + backup). Alloy's remote-write to CK means data survives agent restarts.
- At kyb infra scale (< 2,000 time series), Alloy's embedded scraper has zero performance disadvantage.

**Use Prometheus standalone if:** You are already deeply embedded in the Prometheus ecosystem (Thanos/Mimir/Cortex) and need multi-instance global view. For kyb's three-cluster setup, Alloy + CK is simpler.

### 4.2 Why Not OTel Collector for Metrics

The OTel Collector's `prometheus` receiver accepts **remote writes**, not scrape targets. To use OTel Collector for metrics, you would need:

1. A Prometheus server to do the actual scraping
2. Prometheus configured to remote-write to the OTel Collector
3. OTel Collector to forward OTLP to ClickHouse

That is two agents plus an OTLP hop for what Alloy does in one. The OTel Collector is best positioned as **the trace pipeline** (which it is -- see `unified-otel.md`). For metrics, use a Prometheus-native scraper.

### 4.3 Why Not Vector for Metrics

**Vector cannot scrape Prometheus metrics endpoints.** It has no `prometheus.scrape` source. The only way to get metrics into Vector is:

1. A Prometheus server scrapes → writes to Vector HTTP source → Vector writes to CK (two agents)
2. Services push metrics to Vector HTTP source (requires every service to be modified)
3. OTel Collector scrapes (via Prometheus receiver) → forwards OTLP to Vector → Vector writes to CK (two agents)

Vector is excellent for logs (`unified-vector.md`, `recommended-stack.md`). It should remain the **log pipeline** for now. But for metrics, a Prometheus-native scraper (Prometheus or Alloy) is the right tool.

### 4.4 Why Not Status Quo (No Metrics)

Today's state: heartbeats only (60s granularity, aggregate container counts). No per-container CPU/mem/disk. No cc-connect latency. No cross-cluster comparison.

The cost is:
- **Blind to resource pressure**: A container can be OOM-killed and you only know when patrol catches it 5 minutes later.
- **No performance baselines**: Cannot tell if cc-connect P99 latency degraded from 5s to 30s over a week.
- **No alerting on gradual failures**: Disk fills up over 48 hours. You notice when `docker pull` fails.
- **No capacity planning**: Cannot see "Redis container grew from 50 MB to 200 MB RSS over 3 months."

---

## 5. Implementation Priority

### Phase 1: Metrics Foundation (Week 1)

Goal: Get basic metrics flowing. Do not wait for Alloy.

1. Add Prometheus client to cc-connect (port 9091, `/metrics`). Already designed in `prometheus-scrape.md` section 5. Effort: 2 hours.
2. Deploy cAdvisor on Mac/Orbstack (`gcr.io/cadvisor/cadvisor`, privileged, mounts `/`). Effort: 10 min.
3. Deploy node_exporter on Mac (`brew install node_exporter`). Effort: 5 min.
4. Deploy Prometheus standalone on Mac/Orbstack as interim scraper. Scrape cc-connect + cAdvisor + node_exporter. Effort: 30 min.
5. Add Prometheus datasource in Grafana. Build one "Infra Overview" dashboard (container CPU/mem by name). Effort: 1 hour.

**Why Prometheus first, not Alloy first:** Prometheus config is YAML (familiar), it is known-working, and getting metrics flowing on Day 1 is more important than agent unification. Alloy can replace Prometheus in Phase 2 with a config migration only.

### Phase 2: Alloy Deployment (Week 2-3)

Goal: Replace standalone Prometheus with Alloy for metrics. Add remote clusters.

1. Deploy Grafana Alloy on Mac/Orbstack (`grafana/alloy`). Effort: 30 min.
2. Migrate Prometheus scrape configs to Alloy River syntax. Same targets, same intervals. Effort: 1 hour.
3. Add Docker service discovery (`discovery.docker`) so new containers auto-appear. Effort: 30 min.
4. Configure Alloy to remote-write to ClickHouse (`prometheus.remote_write`). Effort: 15 min.
5. Deploy Alloy on Aliyun and Office. Configure remote-write over Tailscale to central CK. Effort: 1 hour.
6. Stop standalone Prometheus. Alertmanager continues (still needed for alerting). Effort: 5 min.

### Phase 3: Service Exporters (Week 2-4)

Goal: Full visibility into all data services.

1. Deploy PG exporters (x4 versions). Effort: 30 min.
2. Deploy Redis exporter. Effort: 10 min.
3. Deploy Kafka exporter. Effort: 10 min.
4. Deploy ClickHouse exporter (optional, CK has native /metrics). Effort: 10 min.
5. Deploy boss exporter inside each boss container (port 9101). Effort: 30 min.
6. Deploy sing-box metrics exporter (port 9091, `/metrics`). Effort: 15 min.

### Phase 4: Alerting (Week 3-4)

Goal: Route alerts to Feishu. Cover critical failure modes.

1. Deploy Alertmanager on Mac/Orbstack. Effort: 15 min.
2. Configure Feishu webhook receiver (via cc-connect's existing webhook endpoint). Effort: 30 min.
3. Write alert rules for:
   - Container down (any `kyb-infra-*` container not seen for >2 min)
   - cc-connect down or high error rate (>0.1/s for 5 min)
   - cc-connect high latency (P99 > 60s for 2 min)
   - Disk >90% on any cluster
   - Memory >90% on any cluster
   - Container restart loop (>3 restarts in 15 min)
   - Boss heartbeat missed (>2 min without heartbeat)
   - Service exporters unreachable (PG/Redis/Kafka/CK)
4. Test each alert fires correctly. Effort: 1 hour.

### Phase 5: Dashboards (Ongoing)

Goal: Replace `docker stats` and manual checks with Grafana panels.

1. **Infra Overview**: Container CPU/mem/disk by name, all clusters.
2. **cc-connect**: Message throughput, P50/P90/P99 latency, error rate, active sessions, token consumption.
3. **Cluster Health**: Boss uptime, container counts, disk usage, heartbeat timeline.
4. **Data Services**: PG query latency, Redis cache hit rate, Kafka consumer lag, CK query performance.
5. **Alert Dashboard**: Active and recent alerts, grouped by severity.

---

## 6. What This Replaces / Changes

| Current | Replaced by | When |
|---------|-------------|------|
| Nothing (no metrics) | Alloy scraping all exporters | Phase 1-2 |
| Heartbeats (60s aggregate) | Alloy metrics + heartbeats coexist | Phase 2+ |
| Manual `docker stats` | cAdvisor panels in Grafana | Phase 1 |
| Manual `ssh` for disk/mem | node_exporter + Grafana | Phase 1 |
| Patrol-only anomaly detection | Prometheus alerting + patrol | Phase 4 |

**Existing pipelines unchanged:**
- Vector for cc-connect logs (continues)
- Heartbeats shell loop to CK (continues)
- Claude hooks emit-ck.sh to CK (continues)
- Patrol OTel traces (continues)

---

## 7. Diagram: Full Pipeline

```
                         METRICS ONLY
                         ────────────

  ┌────────────┐   ┌──────────────┐   ┌──────────────┐
  │ cc-connect │   │ cAdvisor     │   │ Service      │
  │ :9091      │   │ :8080        │   │ exporters    │
  │ /metrics   │   │ /metrics     │   │ :9xxx/metrics│
  └──────┬─────┘   └──────┬───────┘   └──────┬───────┘
         │                │                   │
         └────────────────┼───────────────────┘
                          │
          ┌───────────────▼────────────────┐
          │  Grafana Alloy                  │
          │  ┌────────────────────────────┐ │
          │  │ prometheus.scrape          │ │
          │  │   ├─ static targets        │ │
          │  │   └─ discovery.docker      │ │
          │  │                            │ │
          │  │ prometheus.relabel         │ │
          │  │   add: cluster, service    │ │
          │  │                            │ │
          │  │ prometheus.remote_write    │ │
          │  └────────────────────────────┘ │
          └───────────────┬─────────────────┘
                          │  Prometheus remote-write
                          │  (protobuf, snappy compressed)
                          ▼
          ┌─────────────────────────────────┐
          │  ClickHouse                     │
          │  (Prometheus remote-write       │
          │   endpoint: /prometheus/write)  │
          │                                 │
          │  Tables (auto-created by CK's   │
          │  Prometheus protocol handler):  │
          │  ┌───────────────────────────┐  │
          │  │ prometheus_samples        │  │
          │  │ prometheus_metrics        │  │
          │  └───────────────────────────┘  │
          │                                 │
          │  OR explicit MergeTree table:   │
          │  ┌───────────────────────────┐  │
          │  │ infra.metrics             │  │
          │  │ (service, metric, value,  │  │
          │  │  tags, timestamp, cluster)│  │
          │  └───────────────────────────┘  │
          └───────────────┬─────────────────┘
                          │
          ┌───────────────▼─────────────────┐
          │  Grafana                        │
          │  (ClickHouse datasource)        │
          │                                 │
          │  ┌───────────────────────────┐  │
          │  │ Dashboards:               │  │
          │  │ Infra Overview            │  │
          │  │ cc-connect Performance    │  │
          │  │ Cluster Health            │  │
          │  │ Service Latency           │  │
          │  │ Alert Dashboard           │  │
          │  └───────────────────────────┘  │
          └─────────────────────────────────┘

                         ALERTING
                         ────────

          ┌─────────────────────────────────┐
          │  Prometheus Alertmanager         │
          │                                 │
          │  Evaluates rules every 30s:     │
          │  - ContainerDown                │
          │  - CcConnectHighLatency         │
          │  - DiskSpaceCritical            │
          │  - ContainerRestartLoop         │
          │                                 │
          │  Routes to Feishu webhook:      │
          │  critical → Feishu @user (30m)  │
          │  warning  → Feishu group (4h)   │
          └─────────────────────────────────┘
```

---

## 8. Comparison Summary

| Aspect | Solo Prometheus | Solo OTel Col. | Solo Vector | **Alloy (recommended)** |
|--------|----------------|----------------|-------------|----------------------|
| Metrics scraping | Yes | Weak (no scraper) | No | **Yes** |
| OTLP traces | No | Yes | Limited | **Yes (receiver)** |
| Log parsing | No | Weak | Yes | **Yes (Loki/filelog)** |
| Docker discovery | No | No | No | **Yes** |
| ClickHouse output | Via remote write | Via exporter | Yes (HTTP) | **Yes (remote write)** |
| Disk buffer | No | Queue only | Yes | **Yes (WAL)** |
| Alerting | +Alertmanager | No | No | **+Alertmanager** |
| Containers needed | 3 (+1) | 2 (+2) | 1 (+2) | **1 (+1 Alertmanager)** |
| Config formats | 3 | 2 | 1 | **1** |
| Memory | ~150 MB | ~180 MB | ~30 MB | **~50 MB** |

---

## 9. References

| Design document | Content |
|----------------|---------|
| `prometheus-scrape.md` | Full Prometheus deployment plan, scrape configs per service, alerting rules, exporter setup |
| `grafana-alloy.md` | Alloy architecture, River config examples, Docker service discovery |
| `recommended-stack.md` | Overall recommended stack (Alloy + Redpanda + CK + Grafana) |
| `otel-vector.md` | OTel Collector + Vector two-stage pipeline (backup plan) |
| `cadvisor-metrics.md` | Container-level metrics from cAdvisor |
| `bridge-metrics-logging.md` | cc-connect metrics specification (counters, histograms, gauges) |
| `node-exporter.md` | Host-level metrics via node_exporter |

---

> **Summary:** Deploy Grafana Alloy as the single metrics collector per cluster. It embeds a Prometheus scraper (same battle-tested code) for all exporter endpoints, supports Docker service discovery for zero-config new containers, and writes Prometheus remote-write to ClickHouse (already running). Pair with Prometheus Alertmanager for Feishu alert routing. This is not a choice between Prometheus, OTel, and Vector -- Alloy is the single binary that subsumes the metrics role of all three. Phase 1 gets cc-connect + cAdvisor metrics flowing via standalone Prometheus (quick win, familiar config). Phase 2 replaces Prometheus with Alloy (config migration only, same targets). Phases 3-5 add service exporters, alerting, and dashboards.

> ／人◕ ‿‿ ◕人＼
