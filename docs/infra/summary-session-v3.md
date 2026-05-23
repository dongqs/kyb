# Observability Design Session v3 -- Comprehensive Summary

**Date:** 2026-05-23
**Scope:** All observability design, review, and standby documents generated during this session
**Total documents produced:** ~90 review docs + 5 design docs + 2 standby configs + 1 cost-security summary + 1 recommended stack synthesis

---

## 1. Executive Summary

This session produced a complete end-to-end observability architecture for kyb infrastructure across three clusters (Mac/Orbstack, Aliyun, Office NUC). The recommended stack is:

```
Service -> Grafana Alloy (unified collector) -> Redpanda (Kafka API buffer) -> ClickHouse (single telemetry lake) -> Grafana (query + visualization)
```

- **Zero new infrastructure** for Phase 0 (Grafana Provisioning as Code)
- **~64 MB RAM** for Phase 1 (Vector log pipeline)
- **~350 MB RAM** for Phase 1-2 (minimal Prometheus stack for alerting)
- **~500 MB RAM** for full vision (Alloy + Redpanda + exporters)
- **~150 MB/90 days** disk for all logs, traces, and events in ClickHouse

All costs are tiny relative to the 32 GB Mac/Orbstack host. The key question is not "can we afford it" but "what gives best ROI first."

---

## 2. Implementation Priorities

### Phase 0 (Day 0) -- NOW -- Zero Infrastructure

| # | Action | Effort | Risk Reduced |
|---|--------|--------|-------------|
| P0 | **Grafana Provisioning as Code** -- datasource YAML, deploy.sh, version-controlled dashboards | 2h | Manual config loss on Grafana rebuild |
| P0 | **cc-connect Hooks Direct-to-CK** -- native cc-connect hooks POST to ClickHouse (6 lifecycle events + heartbeat) | 1h | Message data loss on container restart |

The cc-connect hooks config is already written and tested (cc-hooks-ready.md). Deploy: add hooks block to config.toml, run DDL, restart cc-connect.

### Phase 1 (Day 1-2) -- Log Retention

| # | Action | Effort | Risk Reduced |
|---|--------|--------|-------------|
| P1 | **Vector log pipeline** -- deploy Vector container, create CK tables (cc.message_log, boss.agent_log, patrol.health_checks), label containers | 4h | All structured log data lost on restart |
| P1 | **Create CK tables** for cc-hooks events (cc.hook_events), message log, patrol health, boss agent log, MCP request log | 1h | (prerequisite for pipelines) |
| P1 | **Boss Overview dashboard** -- heartbeat status from all 3 clusters in one view | 1h | No cross-cluster visibility |

### Phase 2 (Week 1-2) -- Alerting & Metrics

| # | Action | Effort | Risk Reduced |
|---|--------|--------|-------------|
| P2 | **Minimal Prometheus stack** -- Prometheus + Alertmanager + node_exporter only (skip service exporters initially) | 4h | No host-level alerting (disk full, host down) |
| P2 | **Alert rules** -- heartbeat alerts via Grafana (from CK data), disk >85% alerts | 1h | Incidents discovered only at patrol cycle |
| P2 | **Cluster Health dashboard** -- CPU/mem/disk per cluster via Prometheus | 1h | No real-time infrastructure overview |
| P2 | **Deploy Vector on remote clusters** (Aliyun, Office) | 2h | Logs from remote clusters not persisted |

### Phase 3 (Week 3-4) -- Depth

| # | Action | Effort | Value |
|---|--------|--------|-------|
| P2 | Full Prometheus stack: cadvisor + service exporters (PG, Redis, Kafka, CK) | 4h | Container-level resource metrics |
| P2 | Patrol structured logging via Vector | 1h | Patrol health queryable in Grafana |
| P2 | Full dashboard suite (Infra Overview, Service Health, cc-connect Messages) | 2h | Complete visibility |

### Phase 4 (Month 2+) -- Future

| Item | Deferred Until | Reason |
|------|---------------|--------|
| Grafana Alloy (unified collector) | Vector + Prometheus stable 3+ weeks | Premature consolidation is churn |
| OTel SDK in cc-connect (traces as log lines) | When modifying cc-connect anyway | Code change, not infra; store as log lines, no new backend |
| Redpanda (Kafka API buffer) | 5+ independent producers or 10+ GB/day | At 400 KB/day, over-engineered |
| Grafana Tempo (trace backend) | 50K+ spans/day (100x current) | Fixed overhead of ~100 MB for 540 spans/day is wasteful |
| Docker events watcher | Phase 3 | Container lifecycle is low-churn |

---

## 3. Standby Teams Ready to Deploy

Two complete, reviewed, ready-to-deploy configurations exist:

### Team 1: cc-connect Hooks Direct-to-ClickHouse

**File:** `docs/infra/standby/cc-hooks-ready.md`
**Status:** **READY** -- config TOML block, CK schema, and deployment steps are fully documented.

- Native cc-connect v1.3.2 hooks, no Vector, no Kafka
- ~90 messages/day, ~34 KB/day -- zero additional infrastructure justified
- 6 lifecycle events subscribed + optional heartbeat
- Direct HTTP POST to `http://host.orb.internal:8123/?query=INSERT+INTO+cc.hook_events+FORMAT+JSONEachRow`
- Fail-open by design: hook failure never blocks message processing
- 2 retries with exponential backoff (500ms-5000ms total window ~1.5s)
- TTL: 90 days on MergeTree table
- **Switch to Kafka path** if: multi-cluster with unreliable WAN, >1000 events/day with zero loss requirement, or Kafka exists for other pipelines

### Team 2: Vector Log Pipeline

**File:** `docs/infra/standby/vector-ready.md`
**Status:** **READY** -- three designs fully reviewed, no open questions.

| Document | Scope |
|----------|-------|
| `vector-pipeline.md` (~1310 lines) | Vector for infra containers (cc-connect, boss, patrol, MCP). Docker log API + label discovery. Full config, transforms, CK schemas, deployment. |
| `unified-vector.md` (~1285 lines) | Expanded: ALL containers via file tail, single `infra.message_log` canonical table, remote cluster forwarding, migration strategy. |
| `otel-vector.md` (~1065 lines) | OTel Collector + Vector combined pipeline for traces/metrics/logs. Two-stage: Collector terminates OTLP, Vector enriches/routes to CK. |

**Phase 0 steps documented:**
1. Create CK tables (cc.message_log, patrol.health_checks, boss.agent_log, mcp.request_log)
2. Deploy Vector container (timberio/vector:0.42.0-alpine, Docker socket, label discovery)
3. Add kyb.logs=true labels to infra containers
4. Verify end-to-end data flow

**Missing:** The actual `vector.toml` config file and SQL schema files need to be created in `docs/infra/vector/` before deployment.

---

## 4. Cost-Security Priorities (from Summary-Cost-Security)

### Phase 0 (do now -- high severity gaps)

| Gap | Action | Reference |
|-----|--------|-----------|
| No real-time token tracking | Deploy `token-tracker.sh` Mode B in boss container | token-cost.md |
| No vulnerability scanning | Deploy Trivy, create CK tables, run baseline scan | vuln-scan.md |
| No secret rotation tracking | Deploy `secret-rotation-exporter`, seed registry | secret-rotation.md |
| No network isolation monitoring | Deploy `kyb-net-monitor` with conntrack + port scan | network-compliance.md |

### Phase 1 (this week -- medium severity)

| Gap | Action | Reference |
|-----|--------|-----------|
| No auto-cleanup for dangling images | Add `docker image prune --force` to `kyb build` | dangling-images.md |
| No disk growth trend tracking | Collect disk metrics every 5 min, compute exhaustion prediction | disk-growth.md |
| No config drift detection | Deploy `kyb-config-snapshot.sh` + `kyb-config-check.sh` | config-drift.md |

### Phase 2 (next week)

- Model usage tracking (model-usage.md)
- Build cache monitoring (cache-hit.md)
- Multi-tenancy audit labeling (multi-tenancy.md)

### Total Phase 0-1 effort: ~24 hours
### Annual cost at risk without Phase 0: Unbounded LLM spend (target $640/mo) + disk exhaustion incidents + credential expiry outages

---

## 5. Risks

### Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| cc-connect crash, all logs lost | High (happens) | Medium | Vector pipeline persists logs to CK |
| Disk full on Aliyun (40 GiB), no alert | Medium | High | Prometheus + node_exporter disk alerting |
| Grafana rebuild, all dashboards/configs lost | Low (rare) | Medium | Grafana provisioning as code in Git |
| Can't debug slow message | High (weekly) | Low-Medium | Logs in CK enable SQL queries |
| Remote cluster offline, unknown for hours | Medium | Medium | Cross-cluster alerts via Prometheus |
| cc-connect hooks TOML -- cc-connect may strip URL query params | Unknown | Medium | nginx shim documented as fallback |

### Execution Risks

| Risk | Mitigation |
|------|-----------|
| "Just deploy everything" syndrome leading to alert fatigue | Phased rollout with exit criteria per phase |
| Config files not version-controlled | All YAML/TOML/River configs in Git from day 1 |
| Remote cluster deployment failure | Documented SSH + docker run commands per cluster |
| Learning curve (River for Alloy, PromQL for Prometheus) | Defer Alloy; use TOML/YAML first, learn PromQL later |

### Decision that Changes Everything

The biggest architectural fork: deploy **Redpanda (Kafka API)** or not.

- **Without Kafka:** Vector -> CK (direct). Simpler, fewer containers, zero additional failure modes. Works at current volume (400 KB/day).
- **With Kafka:** Vector -> Redpanda -> CK. Resilient to CK downtime, enables replay, supports future multi-consumer. Adds 256 MB RAM, one more container to monitor.

**Recommendation (from cost-benefit analysis):** Defer Kafka until 5+ independent producers or 10+ GB/day. At current volume, the cost (512 MB RAM, 5 GB disk, 1 h/week maintenance) exceeds the benefit. Start with direct Vector -> CK. If CK downtime causes data loss, add Kafka as a point fix.

---

## 6. Recommended Stack (Single Source of Truth)

From `docs/infra/reviews/recommended-stack.md`:

```
Layer 1 (Interception):
  - Docker stdout -> collection agent (all containers)
  - OTel SDK -> OTLP (cc-connect, patrol; future)
  - docker events watcher (container lifecycle)
  - Optional MITM proxy for Feishu WS deep debugging

Layer 2 (Collection):
  - Grafana Alloy (unified, 1 daemon) -- future target
  - Vector + OTel Collector (interim, 2 daemons) -- deploy now

Layer 3 (Transport/Buffer):
  - Redpanda (Kafka API, single binary) -- deferred
  - Direct write to CK -- use now

Layer 4 (Storage):
  - ClickHouse (single telemetry lake)
  - Tables: cc.message_log, patrol.event_log, otel.span_log (future),
            kyb.claude_hook_events, kyb.boss_heartbeats, infra.docker_events (future)

Layer 5 (Query/Visualize):
  - Grafana (ClickHouse datasource, Prometheus datasource for alerts)
```

### Deployment per Cluster

| Component | Mac/Orbstack (central) | Aliyun (remote) | Office NUC (remote) |
|-----------|----------------------|-----------------|---------------------|
| Vector (log pipeline) | P0 deploy | Phase 2 | Phase 2 |
| CK tables | P0 create | N/A (central) | N/A (central) |
| Prometheus + Alertmanager | Phase 1 | N/A (scraped via Tailscale) | N/A |
| node_exporter | Phase 1 | Phase 1 | Phase 1 |
| Grafana provisioning | P0 create | N/A (central) | N/A (central) |
| Redpanda | Deferred | Deferred | Deferred |
| cadvisor + service exporters | Phase 3 | Phase 3 | Phase 3 |
| OTel SDK + Collector | Month 2+ | N/A | N/A |

---

## 7. Key Decisions and Their Rationale

### Decision 1: Direct-to-CK over Kafka for hooks

cc-connect hooks POST directly to ClickHouse HTTP endpoint. No Kafka, no Vector.

**Rationale:** ~90 messages/day, ~34 KB/day. Kafka is overkill at this volume. Zero additional infrastructure. Simpler debugging -- one config file, one data path. Fail-open by design.

### Decision 2: Vector over Grafana Alloy for initial deployment

Deploy Vector now (familiar TOML config, proven pipeline). Evaluate Alloy (River config, unified binary) in Month 2+.

**Rationale:** Alloy requires learning River (new config language) for zero benefit over Vector at this stage. Deploying Alloy now means learning River to replace a system that is not deployed yet. The migration path is clear: Alloy parallel-runs with Vector, then Vector is removed.

### Decision 3: Traces as log lines, not Tempo

Instrument cc-connect with OTel SDK but store spans as structured log lines in the existing `cc.message_log` table. No Tempo, no Kafka-for-traces.

**Rationale:** 540 spans/day does not justify 320 MB of dedicated trace infrastructure. Trace-ID-based correlation works fine via SQL JOINs at this volume. Revisit Tempo at 50K+ spans/day.

### Decision 4: Defer Kafka entirely

**Rationale:** One producer (Vector), one consumer (CK), 400 KB/day. Kafka solves problems we don't have: multi-producer, backpressure, replay. The operational cost (512 MB RAM, 5 GB disk, 1 h/week) exceeds the benefit until we reach 5+ producers or 10+ GB/day.

### Decision 5: Grafana Provisioning as Code first (before any telemetry pipeline)

**Rationale:** Zero infrastructure cost, immediate value, enables all downstream visualization. `deploy.sh` reproduces Grafana configuration from scratch. `git diff` shows every dashboard change. Dashboards and alert rules are peer-reviewed before deployment.

---

## 8. Files Created/Modified This Session

### Standby Configs (Ready to Deploy)

| File | Purpose |
|------|---------|
| `docs/infra/standby/cc-hooks-ready.md` | cc-connect direct-to-CK hooks config + CK schema |
| `docs/infra/standby/vector-ready.md` | Vector pipeline deployment plan (3 designs reviewed) |

### Design Docs

| File | Purpose |
|------|---------|
| `docs/infra/observability-design.md` | Chinese-language design summary of 3 approaches |
| `docs/infra/designs/bridge-ck-ingestion.md` | cc-connect message log table + Grafana panels |
| `docs/infra/designs/bridge-hooks-alerting.md` | Hook trigger points + alert rules |
| `docs/infra/designs/bridge-metrics-logging.md` | Metrics logging approach |
| `docs/infra/designs/mcp-observability.md` | MCP observability (future) |
| `docs/infra/designs/issue-automation.md` | Issue auto-detection (cc-connect cron recommended) |

### Key Review Documents

| File | Lines | Scope |
|------|-------|-------|
| `docs/infra/reviews/observability-cost-benefit.md` | ~939 | Complete cost-benefit analysis of 8 approaches (A-H) with phased rollout plan and sensitivity analysis |
| `docs/infra/reviews/recommended-stack.md` | ~596 | Single source of truth: recommended stack with 4-layer architecture and migration path |
| `docs/infra/reviews/summary-cost-security.md` | ~292 | Cost + security priorities from all 90 review docs |
| `docs/infra/reviews/cross-cluster-metrics.md` | ~750+ | Cross-cluster aggregation design across 3+ clusters |
| `docs/infra/reviews/vector-pipeline.md` | ~1310 | Vector pipeline detailed design |
| `docs/infra/reviews/unified-vector.md` | ~1285 | Expanded vector scope (all containers, multi-cluster) |
| `docs/infra/reviews/otel-vector.md` | ~1065 | OTel + Vector combined pipeline |
| `docs/infra/reviews/hooks-direct-ck.md` | ~1300 | cc-connect hooks direct-to-CK detailed review |
| `docs/infra/reviews/hooks-kafka.md` | ~1350 | Kafka pipeline alternative review |

### Operational Docs

| File | Purpose |
|------|---------|
| `docs/infra/5min-patrol-guide.md` | 5-minute patrol checklist with heartbeat files |
| `docs/infra/chat.md` | Session chat log |

---

## 9. Next Steps

### Immediate (< 1 day)

1. **Deploy cc-connect hooks direct-to-CK** -- add hooks block to /root/.cc-connect/config.toml, create cc.hook_events table, restart cc-connect
2. **Create Grafana provisioning** -- `docs/infra/grafana/` with datasource YAMLs, deploy.sh
3. **Write `vector.toml` config file** -- this is the last missing piece before Vector can be deployed

### Short-term (this week)

4. **Deploy Vector container** on Mac/Orbstack
5. **Create CK tables** for all log types
6. **Label infra containers** with kyb.logs=true
7. **Create first dashboards**: Boss Overview, Container Log Explorer
8. **Deploy Prometheus + node_exporter** for host-level alerting
9. **Wire Alertmanager to Feishu** via cc-connect

### Medium-term (next 1-2 weeks)

10. **Deploy remote cluster Vector** (Aliyun, Office)
11. **Add service exporters** (PG, Redis, Kafka, CK)
12. **Full dashboard suite**: Infra Overview, Service Health, cc-connect Messages
13. **Tune alert thresholds** -- measure fatigue baseline

### Long-term (Month 2+)

14. **OTel SDK instrumentation** in cc-connect
15. **Evaluate Grafana Alloy** as unified collector
16. **Evaluate Redpanda** if multi-producer need arises

### Blockers

- `vector.toml` config file and SQL schema files need to be created in `docs/infra/vector/`
- cc-connect hooks TOML URL query param handling needs verification (nginx shim fallback documented)
- Grafana provisioning `deploy.sh` needs implementation

---

> **Total documents in session:** ~90 review docs, 5 design docs, 2 standby configs, 1 cost-security summary, 1 recommended stack synthesis.
> **Implementation effort for Phase 0-1:** ~8 hours. For full vision: ~24 hours.
> **Annual cost at risk without Phase 0:** Unbounded LLM spend + disk exhaustion + credential expiry.
>
> /人◕ ‿‿ ◕人＼
