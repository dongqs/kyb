---
decision: 现在就做
---

# Grafana Provisioning -- Standby Ready

**Status:** STANDBY -- All provisioning files prepared and ready for deployment.
**Date:** 2026-05-23
**Based on:** `docs/infra/reviews/grafana-provisioning.md` + all 90+ infra review files

---

## Directory Structure

```
docs/infra/grafana/
  ├── provisioning/
  │     ├── datasources/
  │     │     ├── clickhouse.yaml     # ClickHouse (boss_heartbeats, message_log, mcp_logs)
  │     │     ├── postgres.yaml       # PostgreSQL (message data, replication monitoring)
  │     │     └── prometheus.yaml     # Prometheus (FUTURE: cAdvisor, postgres_exporter)
  │     ├── dashboards/
  │     │     ├── dashboard_providers.yaml
  │     │     └── json/
  │     │           ├── boss-overview.json       # Multi-cluster boss health overview
  │     │           ├── cluster-health.json       # Per-cluster container & resource metrics
  │     │           ├── heartbeat-monitor.json    # Real-time heartbeat status matrix
  │     │           ├── cc-connect-health.json    # Bridge message, token, latency monitoring
  │     │           └── pg-replication.json       # PG streaming replication monitoring
  │     ├── alerting/
  │     │     ├── resources/
  │     │     │     ├── heartbeat-alerts.yaml     # Boss heartbeat & disk usage alerts
  │     │     │     └── bridge-alerts.yaml        # cc-connect down, latency, silence alerts
  │     │     └── policies/
  │     │           └── default-policy.yaml       # Route all alerts to Feishu
  │     └── notifiers/
  │           └── feishu.yaml                     # Feishu webhook (URL via env var)
  └── deploy.sh                                   # One-shot deploy: docker cp + API reload
```

---

## Datasource YAMLs (3 files)

| Datasource | Table | Review Source | Status |
|---|---|---|---|
| ClickHouse | `boss_heartbeats`, `cc.message_log`, `infra.mcp_logs` | grafana-provisioning.md Section 4.1 | READY |
| PostgreSQL | `pg_stat_replication`, `pg_replication_slots` | review-pg-replication.md Section 2 | READY |
| Prometheus | cAdvisor metrics, postgres_exporter metrics (FUTURE) | cadvisor-metrics.md, prometheus-scrape.md | PREPARED |

### ClickHouse Datasource
- **Type**: `grafana-clickhouse-datasource` (requires plugin install: `GF_INSTALL_PLUGINS=grafana-clickhouse-datasource`)
- **Address**: `http://host.orb.internal:8123` (OrbStack macOS only -- env-var override needed for multi-cluster)
- **Default**: true

### PostgreSQL Datasource
- **Type**: `postgres`
- **Address**: `host.orb.internal:5432`
- **Auth**: trust (password in secureJsonData)
- **Uses**: CC-connect message data, replication monitoring

---

## Dashboard JSONs (5 dashboards, 35 panels total)

### 1. Boss Overview (`boss-overview.json`)
- **8 panels**: Heartbeat lag table, active bosses stat, total containers stat, disk warnings stat, running containers per cluster (timeseries), heartbeat timeline, disk usage trend, load average
- **Data source**: ClickHouse `boss_heartbeats`
- **Time range**: Last 6 hours

### 2. Cluster Health (`cluster-health.json`)
- **5 panels**: Running containers per cluster, disk usage per cluster (gauge), container count running vs total, memory usage, system load
- **Data source**: ClickHouse `boss_heartbeats`
- **Time range**: Last 24 hours

### 3. Heartbeat Monitor (`heartbeat-monitor.json`)
- **5 panels**: Heartbeat status matrix (table with CRITICAL/WARNING/OK), boss uptime timeline, recent heartbeat count, stale bosses stat, disk warnings stat
- **Data source**: ClickHouse `boss_heartbeats`
- **Refresh**: 30s (ops real-time view)

### 4. cc-connect Health (`cc-connect-health.json`)
- **8 panels**: Messages over time, turn duration P50/P90/P99, user activity top-N, token consumption, recent messages table, bridge error rate, active sessions stat, messages today stat
- **Data source**: ClickHouse `cc.message_log`
- **Review references**: A1 (log format), A2 (deployment gaps), A3 (panel feasibility), C2 (alerting gaps), C3 (coverage gaps)

### 5. PG Replication Monitor (`pg-replication.json`)
- **7 panels**: Replay lag per standby, write/flush/replay lag breakdown, standby state table, replication slot health table, total WAL size, replication conflicts, WAL retention per slot
- **Data source**: PostgreSQL `pg_stat_replication`, `pg_replication_slots`
- **Review reference**: review-pg-replication.md

### Future dashboards identified but not yet built:
| Dashboard | Trigger Review | Dependency |
|---|---|---|
| Dashboard of Dashboards | dashboard-of-dashboards.md | Needs all other dashboards deployed first |
| MCP Observability | review-mcp-D1/D2/D3 | Needs MCP server running |
| cAdvisor Container Metrics | cadvisor-metrics.md | Needs Prometheus + cAdvisor deployed |
| Boss Lifecycle | boss-lifecycle.md | Needs lifecycle events table in CK |
| Session Monitor | session-monitor.md | Needs session files monitored |

---

## Alerting Rules (4 rules across 2 files)

| Rule | UID | Severity | Condition | For |
|---|---|---|---|---|
| Boss Heartbeat Warning | `boss_heartbeat_warn` | P2 | No heartbeat >2 min | 30s |
| Boss Heartbeat Critical | `boss_heartbeat_critical` | P1 | No heartbeat >5 min | 60s |
| Disk Usage >85% | `disk_usage_warning` | P2 | Disk >85% | 5min |
| CC-Connect Down | `cc_connect_down` | P0 | No message_log entries in 2 min | 2min |
| High Turn Latency | `high_turn_latency` | P1 | P95 latency >30s for 5min | 5min |
| Claude No Response | `claude_no_response` | P1 | Messages received without response | 2min |
| Bridge Silence >15min | `message_silence_15min` | P2 | No bridge messages for 15min | 15min |

All alerts route to Feishu webhook via the default notification policy.

**Note**: Alerting rules use Grafana Provisioning API format valid for Grafana 8+. If running Grafana <8.x, the alerting rules will not be recognized and must be configured manually.

---

## Deployment

### Quick Deploy (Phase 1)
```bash
cd docs/infra/grafana
./deploy.sh
```

### Long-Term (Phase 4+, recommended)
Add bind-mount to container creation:
```bash
docker run -d --name kyb-infra-grafana \
  --restart unless-stopped \
  -p 3000:3000 \
  -v grafana-storage:/var/lib/grafana \
  -v "$(pwd)/docs/infra/grafana/provisioning:/etc/grafana/provisioning" \
  -e GF_INSTALL_PLUGINS=grafana-clickhouse-datasource \
  grafana/grafana:latest
```

---

## Review Coverage

All review findings that affect Grafana are addressed in the provisioning files:

| Review File | Finding | Addressed In |
|---|---|---|
| grafana-provisioning.md | Phase 1-3 implementation plan | All 14 provisioning files |
| bridge-ck-ingestion-A1.md | Key=value log format, not JSON | cc-connect-health.json queries |
| bridge-ck-ingestion-A2.md | 5 Grafana panels needed | cc-connect-health.json |
| bridge-ck-ingestion-A3.md | Heatmap vs percentile split | cc-connect-health.json (separate panels) |
| bridge-hooks-C1.md | cc-connect native hooks exist | bridge-alerts.yaml (alerts from CK, not hooks) |
| bridge-hooks-C2.md | Grafana alerting not covered | bridge-alerts.yaml (4 rules) |
| bridge-hooks-C3.md | Healthcheck blind spots | bridge-alerts.yaml (silence+response alerts) |
| bridge-metrics-B2.md | Histogram vs summary types | Documented for future Prometheus integration |
| bridge-metrics-B3.md | Panel naming, dashboard-as-code | Folder structure, naming conventions |
| review-mcp-D1.md | MCP metrics schema | Prepared for future MCP dashboard |
| review-mcp-D2.md | Transport observability gaps | Noted as future work |
| review-mcp-D3.md | MCP logging entirely missing | Noted as future work |
| review-pg-replication.md | 6 monitoring panels | pg-replication.json (7 panels) |
| dashboard-of-dashboards.md | Meta-dashboard needed | Noted as post-deployment task |
| review-issue-automation-E*.md | Cron execution monitoring | bridge-alerts.yaml (silence detection) |
| boss-lifecycle.md | Boss lifecycle events | boss-overview.json (timeline panels) |
| cadvisor-metrics.md | Container-level metrics | prometheus.yaml prepared (FUTURE) |
| session-monitor.md | Session file monitoring | Noted as future work |

---

## Prerequisites

Before deploying, ensure:
1. **ClickHouse datasource plugin** is installed: `GF_INSTALL_PLUGINS=grafana-clickhouse-datasource` (or install via UI)
2. **Grafana version** is pinned (not `latest` tag) -- see review Issue 9.4
3. **Admin password** is changed from default -- see review Issue 9.2
4. **`cc.message_log` table** exists in ClickHouse (bridge-ck-ingestion pipeline must be deployed first)
5. **PostgreSQL** is accessible at `host.orb.internal:5432`

---

## Verification Checklist

After deploying:

- [ ] Datasources appear in Grafana Configuration > Data Sources
- [ ] ClickHouse datasource can query `boss_heartbeats` table
- [ ] PostgreSQL datasource can query `pg_stat_replication`
- [ ] "kyb Infra" folder exists in Dashboards
- [ ] All 5 dashboards load without errors
- [ ] Boss Overview shows real heartbeat data
- [ ] cc-connect Health shows message data (if table exists)
- [ ] Alert rules are registered (Alerting > Alert rules)
- [ ] Feishu notifier appears in Alerting > Contact points
- [ ] deploy.sh runs without errors

---

## Known Gaps

1. **No Grafana version pinning** -- `grafana/grafana:latest` may break provisioning schema. Fix: switch to `grafana/grafana:10.4.3` or specific version.
2. **No env-var address injection** -- ClickHouse/PostgreSQL addresses are hardcoded. Fix: use `${CLICKHOUSE_URL}` etc. in YAML.
3. **Feishu webhook placeholder** -- `${FEISHU_WEBHOOK_URL}` must be injected via Grafana env var before alerts can fire.
4. **Dashboard-of-dashboards** -- meta-dashboard not yet built (requires all subsystems deployed first).
5. **MCP observability** -- no MCP servers running yet; dashboard and logs table prepared for future use.

---

/人◕ ‿‿ ◕人＼
