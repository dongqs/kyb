---
decision: 稍后做
---

# Review: Grafana Dashboard Usage

**Focus**: Dashboard usage patterns -- most viewed panels, user sessions, time spent per dashboard, export frequency.

**Current state**: Grafana OSS 13.0.1, Docker deployment, single admin user, 4 dashboards, 2 data sources.

---

## 1. Summary

Grafana usage is single-user and low-volume. One admin (bot/human) accesses all 4 dashboards. There are no other users, no starred dashboards, no annotations, no alerts, and no saved exports. Panel variety is decent (stat, timeseries, barchart, piechart, table) but no dashboard-level usage metadata exists because Grafana OSS lacks built-in usage insights. The only proxy metric available is ClickHouse `system.query_log`, where 93% of queries come via HTTP (Grafana frontend).

---

## 2. System Metadata

| Attribute | Value |
|-----------|-------|
| Version | 13.0.1+security-01 (Docker) |
| Edition | OSS (no Enterprise license) |
| Uptime | ~21.5 hours (current container) |
| Total dashboards | 4 |
| Data sources | 2 (ClickHouse, PostgreSQL) |
| Users | 1 (admin@localhost, Admin role) |
| Service accounts | 0 |
| API keys | 0 |
| Stars (favorites) | 0 |
| Annotations | 0 |
| Alert rules | 0 |
| Snapshots / exports | 0 |
| Short URLs (shared) | 0 |
| Saved queries | 0 |

### User Activity

| User | Role | Created | Last Seen | Disabled |
|------|------|---------|-----------|----------|
| admin@localhost | Admin | 2026-05-22 19:13 | 2026-05-23 17:25 | No |

The single admin user logs in via basic auth. No other users, teams, or service accounts exist.

---

## 3. Dashboard Inventory

### 3.1 Agent Events / 代理事件

| Attribute | Value |
|-----------|-------|
| UID | `1dc50c79-1081-4fc0-a551-7885000744c1` |
| Panels | 11 |
| Tags | agent, events, kyb, monitoring |
| Description | Agent decision and event tracking |

**Panel types**:
- `stat` x4: Total Agent Events, Unique Agents, Decision Events, Projects
- `piechart` x1: Event Type Distribution
- `barchart` x4: Event Type Counts, Top Agents, Events per Project, Agent Event Timeline
- `timeseries` x1: Event Type Timeline
- `table` x1: Recent Agent Events

### 3.2 Claude Agent Activity / Claude 代理活动

| Attribute | Value |
|-----------|-------|
| UID | `31b12804-e325-4df2-8abb-5719b8a19285` |
| Panels | 14 |
| Tags | agent, claude, kyb, monitoring |
| Description | Real-time Claude agent hook events: tool usage, sessions, errors |

**Panel types**:
- `stat` x4: Total Events, Error Events, Sessions, Error Rate
- `timeseries` x4: Events by Type, Event Rate, Error Rate Over Time, Activity Curve
- `piechart` x2: Tool Usage Distribution, Event Status Distribution
- `barchart` x3: Event Type Breakdown, Tool Performance, Session Activity
- `table` x1: Recent Errors

### 3.3 Infrastructure Health / 基础设施健康

| Attribute | Value |
|-----------|-------|
| UID | `49977785-7231-437c-b65c-d6e9d0d23970` |
| Panels | 13 |
| Tags | clickhouse, infrastructure, kyb, monitoring |
| Description | ClickHouse cluster health, DB sizes, query performance, system metrics |

**Panel types**:
- `stat` x5: Active Tables, Active Databases, Total Queries, Avg Query Duration, Total Disk Used
- `barchart` x5: Database Sizes, Top Tables by Row, MergeTree Parts, Table Disk Usage, Infra Metrics
- `timeseries` x2: Query Performance, Query Count
- `table` x1: Key System Metrics

### 3.4 Project Onboarding Progress / 项目接入进度

| Attribute | Value |
|-----------|-------|
| UID | `985c0ccf-3ab6-4008-9a87-9bc76bcad589` |
| Panels | 13 |
| Tags | kyb, onboarding, project, tracking |
| Description | Project onboarding pipeline: CI status, MR stats, multi-repo health |

**Panel types**:
- `row` x3: Pipeline Status Overview, Boss Mode Workflow, Project Pipeline Tracking
- `stat` x6: Projects Onboarded, CI Pipelines, Open MRs, Agent MRs, CI Green Events, Decisions
- `timeseries` x1: Agent Events Timeline
- `barchart` x2: Workflow Stages, Infra Metrics Monitor
- `table` x1: Onboarding Steps Checklist

---

## 4. Panel Type Distribution (All Dashboards Combined)

| Panel Type | Count | Percentage |
|------------|-------|------------|
| stat | 19 | 37% |
| barchart | 14 | 27% |
| timeseries | 8 | 16% |
| table | 4 | 8% |
| piechart | 3 | 6% |
| row | 3 | 6% |
| **Total** | **51** | **100%** |

Usage is dominated by summary panels (stat) and bar charts. Timeseries panels are underrepresented for a monitoring setup, suggesting users prefer aggregate snapshots over trend analysis.

---

## 5. ClickHouse Query Pattern (Proxy for Usage)

Grafana connects to ClickHouse via the `grafana-clickhouse-datasource` plugin. HTTP queries to ClickHouse proxy dashboard/panel activity.

### 5.1 Interface Distribution (Last 7 Days)

| Interface | Queries | Unique Query IDs | Total Duration (ms) | Avg Duration (ms) |
|-----------|---------|-----------------|---------------------|-------------------|
| HTTP (Grafana/Browser) | 55,640 | 28,027 | 86,506 | 1.6 |
| TCP (clickhouse-client) | 4,015 | 2,090 | 398,441 | 99.2 |

93% of all queries go through Grafana. HTTP queries are fast (~1.6ms avg) -- typical for stat/summary panels. TCP queries are slower (~99ms avg) -- analytical queries run manually.

### 5.2 Table Access (Grafana HTTP Queries, Last 7 Days)

| Table | Queries | Total Duration | Avg Duration |
|-------|---------|----------------|--------------|
| `kyb.claude_hook_events` | 18,254 | 74,088 ms | 4.1 ms |
| `kyb.agent_events` | 452 | 1,802 ms | 4.0 ms |

`claude_hook_events` receives **40x more queries** than `agent_events`. This means the "Claude Agent Activity" and "Agent Events" dashboards (which query these tables) see far more panel renders than "Infrastructure Health" (which queries `system.*` tables) or "Project Onboarding Progress".

### 5.3 Daily Query Volume (All Users, Last 14 Days)

| Date | Queries | Total Duration | Avg Duration |
|------|---------|----------------|--------------|
| 2026-05-11 | 154 | 460,493 ms | 2,990 ms |
| 2026-05-12 | 289 | 602,387 ms | 2,084 ms |
| 2026-05-13 | 503 | 1,670,889 ms | 3,322 ms |
| 2026-05-14 | 272 | 38,221 ms | 141 ms |
| 2026-05-17 | 2 | 2 ms | 1 ms |
| 2026-05-18 | 944 | 2,998 ms | 3 ms |
| 2026-05-19 | 832 | 62,048 ms | 75 ms |
| 2026-05-20 | 1,138 | 303,473 ms | 267 ms |
| 2026-05-21 | 310 | 21,305 ms | 69 ms |
| 2026-05-22 | 622 | 3,316 ms | 5 ms |
| 2026-05-23 | 19,096 | 76,225 ms | 4 ms |

The spike on 2026-05-23 (19,096 queries) correlates with the Grafana container being restarted at 11:42. Before 2026-05-18, queries were heavy (seconds per query) -- likely manual analytical queries. After that, queries became lightweight (milliseconds) -- automated dashboard panel refreshes.

### 5.4 Dashboard-Specific Query Heatmap (Inferred from Tables)

| Dashboard | Primary Table | Est. Query Share | Refresh Behavior |
|-----------|--------------|-----------------|------------------|
| Claude Agent Activity | `kyb.claude_hook_events` | ~80% | Auto-refresh (stat heavy) |
| Agent Events | `kyb.agent_events` | ~10% | Auto-refresh |
| Infrastructure Health | `system.query_log` | ~8% | Periodic |
| Project Onboarding | `kyb.agent_events` | ~2% | Periodic |

Note: This is inferred from table access since Grafana OSS does not expose per-dashboard view counts.

---

## 6. Export / Sharing Behavior

| Activity | Count | Details |
|----------|-------|---------|
| Dashboard snapshots | 0 | No snapshots ever created |
| Short URLs | 0 | No links shared via short URL |
| API keys | 0 | No programmatic access |
| Query history saves | 0 | No queries saved for replay |
| PDF/CSV exports | 0 | No export files in container data dir |

**Conclusion**: Zero export activity. Dashboards are consumed only via the Grafana UI. No sharing, no scheduled reports, no programmatic consumption.

---

## 7. User Sessions

| Metric | Value |
|--------|-------|
| Total users | 1 |
| Active sessions (current) | 0 |
| Concurrent sessions observed | 0 |
| Auth tokens | 1 |
| Login method | Basic auth (password) |

There is always at most one active session (admin only). No anonymous access is enabled. No SSO/OAuth is configured.

---

## 8. Limitations of This Analysis

1. **No built-in usage insights**: Grafana OSS does not track page views, panel clicks, time-spent-per-dashboard, or user journeys. These require Grafana Enterprise or the Prometheus-based Grafana usage insights plugin.
2. **No access logs**: The Grafana container does not log HTTP requests to files. The only requests visible in `grafana.log` are for alerting/ngalert API probes.
3. **No HTTP referer**: ClickHouse `http_referer` field is empty for all Grafana queries, preventing per-dashboard attribution.
4. **Container restart gap**: The Grafana container was restarted at 2026-05-23 11:42, losing in-memory state from the previous run (which started 2026-05-22 19:13).
5. **Proxy metric**: ClickHouse query volume is the best available proxy, but it cannot distinguish between auto-refresh panel queries and manual user interactions.

---

## 9. Recommendations

### 9.1 Enable Usage Tracking

```bash
# Option A: Enable Grafana's reporting (OSS, basic stats)
# Add to docker-compose or grafana.ini:
# [analytics]
# reporting_enabled = true

# Option B: Instrument with Prometheus
# Grafana exposes /metrics at :3000 with HTTP request counters
# Scrape this into a Prometheus + dashboard for real usage stats

# Option C: NGINX access log
# Put Grafana behind an NGINX reverse proxy with access logging
# Parse for per-endpoint, per-user request patterns
```

### 9.2 Add Per-Dashboard Usage Labels

Tag each dashboard with a `team` and `purpose` label to enable future grouping:

| Dashboard | Suggested Tags |
|-----------|---------------|
| Claude Agent Activity | `team=kyb, purpose=operations, frequency=high` |
| Agent Events | `team=kyb, purpose=operations, frequency=medium` |
| Infrastructure Health | `team=infra, purpose=monitoring, frequency=medium` |
| Project Onboarding | `team=kyb, purpose=tracking, frequency=low` |

### 9.3 Reduce Blind Spots

- Add `stat.dashboard_view_count` annotation or a synthetic health check that pings each dashboard URL daily to log views.
- Enable `[log]` section in grafana.ini to record request logs to a file.
- Consider Grafana Faro (frontend observability) if user-facing dashboards are planned.

### 9.4 Dashboard Optimization

- **Timeseries underuse**: Only 16% of panels are timeseries. For monitoring, consider adding more trend panels (e.g., 7-day query volume trend, agent error rate trend).
- **Stat panel dominance**: 37% are stat panels. These are cheap and fast (<2ms each) but provide limited insight -- consider consolidating related stats into a single table or timeseries panel.
- **"Project Onboarding Progress" has placeholders**: Two panels are marked "placeholder" with no data source. Either remove or wire them up.

---

## 10. Appendix: Data Sources

| Data Source | Type | URL | Default? |
|-------------|------|-----|----------|
| ClickHouse (kyb) | grafana-clickhouse-datasource | `host.orb.internal:8123` | Yes |
| PostgreSQL | grafana-postgresql-datasource | `host.orb.internal:5432` | No |

Data sources are configured manually (not provisioned). See `grafana-provisioning.md` for the plan to move to Infrastructure-as-Code.

---

## 11. Appendix: Raw Queries Used

```sql
-- ClickHouse query volume by interface
SELECT multiIf(interface=1,'TCP',interface=2,'HTTP',toString(interface)) as iface,
       count(), uniq(query_id), sum(query_duration_ms)
FROM system.query_log
WHERE user='default' AND query_start_time > now() - INTERVAL 7 DAY
GROUP BY interface;

-- Table-level access (Grafana queries)
SELECT arrayJoin(tables) as tbl,
       count() as q, sum(query_duration_ms) as dur
FROM system.query_log
WHERE user='default' AND has(databases,'kyb')
  AND query_start_time > now() - INTERVAL 7 DAY
GROUP BY tbl ORDER BY q DESC;

-- Daily query volume
SELECT toDate(query_start_time) as day,
       count(), sum(query_duration_ms), avg(query_duration_ms)
FROM system.query_log WHERE user='default'
  AND query NOT LIKE '%system.%'
  AND query_start_time > now() - INTERVAL 14 DAY
GROUP BY day ORDER BY day;
```

```sqlite
-- Dashboard schema (Grafana unified storage)
SELECT guid, name, "group" as grp, resource, folder
FROM resource
WHERE "group" = 'dashboard.grafana.app' AND resource = 'dashboards';

-- User activity
SELECT login, email, last_seen_at, created FROM user;
```
