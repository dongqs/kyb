---
decision: 稍后做
---

# Review: Grafana Provisioning as Code

**评审焦点**: Grafana 面板、数据源、告警规则的 Git 化管理
**当前状态**: Grafana 容器运行中，Datasource 有手动配置，Dashboards 和 Alerting 目录为空

---

## 1. Summary

当前 Grafana 处于"手工运维"状态：数据源在容器内手动创建，面板不存在，告警不存在。每次重建容器都会丢失配置。推荐转为**声明式 Provisioning-as-Code**，所有配置以 YAML/JSON 形式存在 `docs/infra/grafana/` 目录下，通过 bind-mount 注入容器，Git 管理变更历史。

---

## 2. Current State Assessment

```
kyb-infra-grafana (容器)
  ├── provisioning/datasources/
  │     ├── clickhouse.yaml      ← 手动创建，指针为 host.orb.internal（仅 macOS 可用）
  │     ├── pg-datasource.yaml   ← 手动创建
  │     └── datasources.yaml     ← 空列表占位
  ├── provisioning/dashboards/   ← 空（无面板）
  ├── provisioning/alerting/     ← 空（无告警规则）
  ├── provisioning/notifiers/    ← 空（无通知渠道）
  ├── provisioning/plugins/      ← 空
  └── provisioning/access-control/ ← 空
```

问题：
- **不可复现** — 容器重建后配置丢失，需要重新手动创建
- **不可审计** — 谁在什么时候改了数据源？没有历史记录
- **无面板** — 心跳数据在 ClickHouse 里但无人看，巡检靠手工 `SELECT *`
- **无告警** — Boss 挂了没人知道，巡检发现时可能已经过了好几个周期
- **无通知渠道** — 即使有告警也没有飞书/钉钉通知出口
- **数据源地址硬编码** — `host.orb.internal` 只在 OrbStack macOS 环境下可解析，迁移到其他集群（Aliyun/Office）需要手动改

---

## 3. Proposed Architecture

```
docs/infra/grafana/
  ├── provisioning/                     # Grafana provisioning directory
  │     ├── datasources/               # Data sources
  │     │     ├── clickhouse.yaml
  │     │     ├── postgres.yaml
  │     │     └── prometheus.yaml       # Future: Prometheus for Docker metrics
  │     ├── dashboards/                # Dashboard provider config + JSON models
  │     │     ├── dashboard_providers.yaml
  │     │     └── json/
  │     │           ├── boss-overview.json
  │     │           ├── cluster-health.json
  │     │           └── heartbeat-monitor.json
  │     ├── alerting/                  # Alert rules
  │     │     ├── resources/
  │     │     │     ├── heartbeat-alerts.yaml
  │     │     │     └── bridge-alerts.yaml
  │     │     └── policies/
  │     │           └── default-policy.yaml
  │     └── notifiers/                 # Notification channels
  │           └── feishu.yaml
  └── deploy.sh                        # One-shot deploy: docker cp + restart
```

### 3.1 Deployment Mechanism

当前容器没有 bind-mount provisioning 目录。最小侵入方案：`deploy.sh` 脚本用 `docker cp` 同步文件 + 触发热加载。

```bash
#!/bin/bash
# deploy.sh — Deploy Grafana provisioning config
set -euo pipefail

GRAFANA_CONTAINER="kyb-infra-grafana"
PROVISIONING_DIR="./provisioning"

echo "=> Syncing provisioning config to ${GRAFANA_CONTAINER}..."
docker cp "${PROVISIONING_DIR}" "${GRAFANA_CONTAINER}:/etc/grafana/provisioning"

echo "=> Triggering hot-reload via API..."
ADMIN_PASSWORD=$(docker exec "${GRAFANA_CONTAINER}" \
  cat /etc/grafana/grafana.ini 2>/dev/null \
  | grep -oP '(?<=admin_password = ).*' || echo "admin")

docker exec "${GRAFANA_CONTAINER}" \
  curl -s -X POST "http://admin:${ADMIN_PASSWORD}@localhost:3000/api/admin/provisioning/dashboards/reload" \
  -H "Content-Type: application/json"

docker exec "${GRAFANA_CONTAINER}" \
  curl -s -X POST "http://admin:${ADMIN_PASSWORD}@localhost:3000/api/admin/provisioning/alerting/reload" \
  -H "Content-Type: application/json"

echo "=> Done."
```

**长期方案**: 将 provisioning 目录 bind-mount 到容器，实现实时同步。需要停止容器重新创建：

```bash
docker rm -f kyb-infra-grafana

docker run -d --name kyb-infra-grafana \
  --restart unless-stopped \
  -p 3000:3000 \
  -v grafana-storage:/var/lib/grafana \
  -v "$(pwd)/docs/infra/grafana/provisioning:/etc/grafana/provisioning" \
  -e GF_INSTALL_PLUGINS=grafana-clickhouse-datasource \
  grafana/grafana:latest
```

---

## 4. Datasource YAML Definitions

### 4.1 ClickHouse (Primary Datasource)

```yaml
# docs/infra/grafana/provisioning/datasources/clickhouse.yaml
apiVersion: 1

datasources:
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    access: proxy
    url: http://host.orb.internal:8123
    isDefault: true
    editable: false
    jsonData:
      server: host.orb.internal
      port: 8123
      protocol: http
```

> **注意**：`host.orb.internal` 只在 OrbStack macOS 上可解析。多集群部署时：
> - Aliyun: ClickHouse 不在本地，需要通过 Tailscale 访问 Mac 上的 CK
> - Office: 同上
> - 建议通过环境变量或 `GF_DATASOURCES_CLICKHOUSE_URL` 注入

### 4.2 PostgreSQL (CC-Connect 数据)

```yaml
# docs/infra/grafana/provisioning/datasources/postgres.yaml
apiVersion: 1

datasources:
  - name: PostgreSQL
    type: postgres
    access: proxy
    url: host.orb.internal:5432
    database: postgres
    user: postgres
    secureJsonData:
      password: postgres
    jsonData:
      sslmode: disable
      postgresVersion: 1600
      timescaledb: false
    editable: false
```

### 4.3 Prometheus (Future — Docker Metrics)

```yaml
# docs/infra/grafana/provisioning/datasources/prometheus.yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://kyb-infra-prometheus:9090
    isDefault: false
    editable: false
```

---

## 5. Dashboard JSON Definitions

### 5.1 Dashboard Provider Config

```yaml
# docs/infra/grafana/provisioning/dashboards/dashboard_providers.yaml
apiVersion: 1

providers:
  - name: 'kyb-infra'
    orgId: 1
    folder: 'kyb Infra'
    folderUid: 'kyb-infra'
    type: file
    disableDeletion: true
    editable: false
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/provisioning/dashboards/json
```

### 5.2 Boss Overview Dashboard

第一块面板：所有 Cluster Boss 的综合视图。数据源：ClickHouse `boss_heartbeats` 表。

```json
{
  "title": "Boss Overview",
  "uid": "boss-overview",
  "description": "Multi-cluster boss heartbeats & health",
  "tags": ["kyb", "infra", "boss"],
  "time": { "from": "now-6h", "to": "now" },
  "panels": [
    {
      "title": "Boss Heartbeat Lag",
      "type": "table",
      "datasource": "ClickHouse",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [{
        "refId": "A",
        "query": "SELECT\n  boss_id,\n  cluster,\n  timestamp,\n  dateDiff('second', timestamp, now()) AS lag_seconds,\n  docker_running,\n  docker_total,\n  disk_used_pct,\n  if(lag_seconds > 120, 'DOWN', if(lag_seconds > 60, 'WARN', 'OK')) AS status\nFROM boss_heartbeats\nWHERE (boss_id, timestamp) IN (\n  SELECT boss_id, max(timestamp)\n  FROM boss_heartbeats\n  GROUP BY boss_id\n)\nORDER BY cluster"
      }]
    },
    {
      "title": "Boss Uptime (Heartbeat Received)",
      "type": "stat",
      "datasource": "ClickHouse",
      "gridPos": { "h": 4, "w": 4, "x": 0, "y": 8 },
      "targets": [{
        "refId": "A",
        "query": "SELECT count(DISTINCT boss_id) FROM boss_heartbeats WHERE timestamp > now() - 120"
      }],
      "description": "Bosses that reported heartbeat in the last 2 minutes"
    },
    {
      "title": "Docker Containers (All Clusters)",
      "type": "stat",
      "datasource": "ClickHouse",
      "gridPos": { "h": 4, "w": 4, "x": 4, "y": 8 },
      "targets": [{
        "refId": "A",
        "query": "SELECT sum(docker_total) FROM boss_heartbeats WHERE timestamp > now() - 120"
      }]
    },
    {
      "title": "Disk Usage Warning",
      "type": "stat",
      "datasource": "ClickHouse",
      "gridPos": { "h": 4, "w": 4, "x": 8, "y": 8 },
      "targets": [{
        "refId": "A",
        "query": "SELECT count(DISTINCT boss_id) FROM boss_heartbeats WHERE disk_used_pct > 85 AND timestamp > now() - 120"
      }]
    },
    {
      "title": "Heartbeat Timeline",
      "type": "timeseries",
      "datasource": "ClickHouse",
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 12 },
      "targets": [{
        "refId": "A",
        "query": "SELECT\n  timestamp,\n  boss_id,\n  docker_running\nFROM boss_heartbeats\nORDER BY timestamp"
      }]
    }
  ]
}
```

### 5.3 Cluster Health Dashboard

```json
{
  "title": "Cluster Health",
  "uid": "cluster-health",
  "description": "Per-cluster container and resource metrics",
  "tags": ["kyb", "infra", "cluster"],
  "time": { "from": "now-24h", "to": "now" },
  "panels": [
    {
      "title": "Running Containers per Cluster",
      "type": "timeseries",
      "datasource": "ClickHouse",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 0 },
      "targets": [{
        "refId": "A",
        "query": "SELECT\n  timestamp,\n  cluster,\n  docker_running\nFROM boss_heartbeats\nWHERE $__timeFilter(timestamp)\nORDER BY timestamp"
      }]
    },
    {
      "title": "Disk Usage per Cluster",
      "type": "gauge",
      "datasource": "ClickHouse",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "targets": [{
        "refId": "A",
        "query": "SELECT\n  cluster,\n  argMax(disk_used_pct, timestamp) AS disk_pct\nFROM boss_heartbeats\nWHERE timestamp > now() - 120\nGROUP BY cluster"
      }]
    }
  ]
}
```

### 5.4 Heartbeat Monitor Dashboard

专注告警前置的面板，用于巡检时快速判断是否有 Boss 失联：

```json
{
  "title": "Heartbeat Monitor",
  "uid": "heartbeat-monitor",
  "description": "Real-time boss heartbeat monitoring",
  "tags": ["kyb", "infra", "heartbeat"],
  "time": { "from": "now-30m", "to": "now" },
  "refresh": "30s",
  "panels": [
    {
      "title": "Heartbeat Status Matrix",
      "type": "table",
      "datasource": "ClickHouse",
      "gridPos": { "h": 12, "w": 24, "x": 0, "y": 0 },
      "targets": [{
        "refId": "A",
        "query": "SELECT\n  boss_id,\n  cluster,\n  timestamp AS last_heartbeat,\n  dateDiff('second', timestamp, now()) AS lag_seconds,\n  docker_running,\n  docker_total,\n  disk_used_pct,\n  multiIf(\n    lag_seconds > 300, 'CRITICAL',\n    lag_seconds > 120, 'WARNING',\n    'OK'\n  ) AS alert_level\nFROM boss_heartbeats\nWHERE (boss_id, timestamp) IN (\n  SELECT boss_id, max(timestamp)\n  FROM boss_heartbeats\n  GROUP BY boss_id\n)\nORDER BY alert_level, lag_seconds DESC"
      }]
    }
  ]
}
```

---

## 6. Alerting Rules as YAML

Grafana 8+ 支持 provisioning 告警规则。以下是一个完整的告警体系。

### 6.1 Heartbeat Alerts

```yaml
# docs/infra/grafana/provisioning/alerting/resources/heartbeat-alerts.yaml
apiVersion: 1
groups:
  - name: heartbeat-alerts
    folder: kyb-infra-alerts
    interval: 60s
    rules:
      - uid: boss_heartbeat_warn
        title: "Boss Heartbeat Warning (>2 min stale)"
        condition: "A"
        data:
          - refId: A
            queryType: sql
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT
                  boss_id,
                  count() AS heartbeat_count
                FROM boss_heartbeats
                WHERE timestamp > now() - 120
                GROUP BY boss_id
              format: table
        noDataState: Alerting
        execErrState: Alerting
        for: 30s
        annotations:
          summary: "Boss heartbeat warning — {{ $labels.boss_id }} stale for >2 min"
          runbook_url: "docs/infra/patrol-guide.md"
        labels:
          severity: warning
          p: "2"

      - uid: boss_heartbeat_critical
        title: "Boss Heartbeat Critical (>5 min stale)"
        condition: "A"
        data:
          - refId: A
            queryType: sql
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT
                  boss_id,
                  count() AS heartbeat_count
                FROM boss_heartbeats
                WHERE timestamp > now() - 300
                GROUP BY boss_id
              format: table
        noDataState: Alerting
        execErrState: Alerting
        for: 60s
        annotations:
          summary: "BOSS DOWN — {{ $labels.boss_id }} heartbeat missing for >5 min!"
          runbook_url: "docs/infra/disaster-recovery.md"
        labels:
          severity: critical
          p: "1"

      - uid: disk_usage_warning
        title: "Disk Usage > 85%"
        condition: "A"
        data:
          - refId: A
            queryType: sql
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT
                  boss_id,
                  argMax(disk_used_pct, timestamp) AS disk_pct
                FROM boss_heartbeats
                WHERE timestamp > now() - 120
                GROUP BY boss_id
                HAVING disk_pct > 85
              format: table
        for: 5m
        annotations:
          summary: "Disk >85% on {{ $labels.boss_id }} ({{ $values.disk_pct }}%)"
        labels:
          severity: warning
          p: "2"
```

### 6.2 Bridge/CC-Connect Alerts (Future)

```yaml
# docs/infra/grafana/provisioning/alerting/resources/bridge-alerts.yaml
apiVersion: 1
groups:
  - name: bridge-alerts
    folder: kyb-infra-alerts
    interval: 30s
    rules:
      - uid: cc_connect_down
        title: "CC-Connect Container Down"
        condition: "A"
        data:
          - refId: A
            queryType: sql
            relativeTimeRange:
              from: 120
              to: 0
            datasourceUid: clickhouse
            model:
              rawSql: |-
                SELECT 1
                FROM cc.message_log
                WHERE event_time > now() - 60
                LIMIT 1
        noDataState: Alerting
        for: 2m
        annotations:
          summary: "CC-Connect appears down — no message_log entries in 2 min"
        labels:
          severity: critical
          p: "1"
```

### 6.3 Default Notification Policy

```yaml
# docs/infra/grafana/provisioning/alerting/policies/default-policy.yaml
apiVersion: 1
policies:
  - orgId: 1
    receiver: feishu
    group_by: ["severity"]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 30m
```

---

## 7. Notifier: Feishu Integration

飞书群通知作为唯一的告警出口（当前 infra 没有邮件/PagerDuty/Slack）。

```yaml
# docs/infra/grafana/provisioning/notifiers/feishu.yaml
apiVersion: 1
notifiers:
  - name: Feishu Infra Alerts
    type: webhook
    uid: feishu
    orgId: 1
    isDefault: true
    settings:
      url: "${FEISHU_WEBHOOK_URL}"
      httpMethod: POST
      autoResolve: true
      sendReminder: true
      frequency: "30m"
    secureSettings:
      url: "${FEISHU_WEBHOOK_URL}"
```

> **注意**：飞书 Webhook URL 不能明文存于 Git。建议通过 `GF_NOTIFIERS_FEISHU_SETTINGS_URL` 环境变量传入，或使用 Grafana 的 secure settings 机制。

---

## 8. Migration Plan

### Phase 1: Provisioning Foundation (T+0)
1. 创建 `docs/infra/grafana/` 目录结构
2. 编写 datasource YAML（ClickHouse + PostgreSQL）
3. 编写 dashboard provider YAML
4. 编写 `deploy.sh` 脚本
5. 执行 `deploy.sh`，验证数据源和面板加载成功
6. git push

### Phase 2: Dashboard Design (T+1)
1. 编写 `boss-overview.json` 面板
2. 编写 `cluster-health.json` 面板
3. 编写 `heartbeat-monitor.json` 面板
4. 通过 `deploy.sh` 部署，验证面板渲染正确
5. 调整 SQL 查询优化显示

### Phase 3: Alerting (T+2)
1. 编写 heartbeat alert rules
2. 编写 notifier YAML（飞书 webhook）
3. 配置飞书 webhook 环境变量
4. 部署并测试告警触发
5. 模拟 Boss 断连，验证告警到达飞书群

### Phase 4: Long-Term (T+3+)
1. 切换为 bind-mount 部署（去掉 `deploy.sh`，改为 `docker run -v`）
2. 添加更多面板（cc-connect metrics, MCP logs, token usage）
3. 集成 Prometheus 数据源（Docker 容器级别 metrics）
4. 编写告警自愈 playbook（自动重启容器、自动扩容 etc.）

---

## 9. Issues & Risks

### 9.1 ClickHouse Address Not Portable

当前 ClickHouse 数据源使用 `host.orb.internal:8123`，这个地址只在 OrbStack macOS 上可解析。Aliyun 和 Office 集群的 Boss 需要从远程访问 ClickHouse。

**建议**：
- 短期：数据沿用当前地址，因为 Grafana 跑在 Mac 上，CK 也跑在 Mac 上
- 中期：写 provisioning 时用环境变量替换地址，如 `url: "${CLICKHOUSE_URL}"`
- 长期：CK 前面加一层负载均衡（如 haproxy 或 Tailscale Funnel），实现统一入口

### 9.2 Grafana API Auth for Hot-Reload

`deploy.sh` 需要 Grafana admin 密码来触发 provisioning reload。当前密码是默认值（admin/admin），**需要更改**。

```bash
# 更换密码
docker exec kyb-infra-grafana grafana cli admin reset-admin-password <new-password>
```

之后将密码存入 `~/.config/kyb/secrets.yml`（Git ignored）或环境变量。

### 9.3 No Built-in Docker Metrics

当前心跳数据只有 5 个字段（docker_running, docker_total, disk_used_pct, mem_used_pct, load_1m），粒度很粗。

**建议**：
- 在心跳脚本中增加更多 metrics（CPU 温度、网络流量、zombie 进程数）
- 或后期部署 cadvisor + Prometheus，替代 shell 脚本心跳

### 9.4 Alerting Rule Schema Fragility

Grafana 的 provisioning alerting rules API 在 8.x-10.x 之间经历了多次 breaking changes。YAML 格式可能因版本不同而解析失败。

**建议**：
- 锁定 Grafana 版本（当前 `latest` 标签要换成固定版本如 `10.4.3`）
- 对接 `grafana-version` 进行 provisioning schema 验证 CI
- 在 `deploy.sh` 中加语法检查步骤

### 9.5 Dashboard JSON Maintainability

Grafana dashboard JSON 是机器生成的格式，手动编写容易漏字段。每次在 UI 上调整面板后导出 JSON 覆盖文件即可。

**建议工作流**：
1. 在 Grafana UI 中拖拽设计面板
2. 通过 `docker exec` 或 API 导出 JSON
3. 将 JSON 放入 `dashboards/json/` 目录 + 检查差异
4. commit + push

```bash
# 导出已有面板的脚本片段
docker exec kyb-infra-grafana \
  curl -s "http://admin:${PASSWORD}@localhost:3000/api/dashboards/uid/boss-overview" \
  | jq '.dashboard' > dashboards/json/boss-overview.json
```

---

## 10. Prioritized Recommendations

| # | Item | Priority | Effort | Reason |
|---|------|----------|--------|--------|
| 1 | 创建 `docs/infra/grafana/` 目录 + datasource YAML | P0 | 15min | 不丢失数据源配置 |
| 2 | 编写 `deploy.sh` + 执行 | P0 | 30min | 最小可重复部署 |
| 3 | Boss Overview 面板 | P1 | 1h | 巡检时能看到所有 Boss 状态 |
| 4 | Heartbeat Monitor 面板 | P1 | 30min | 快速判断哪个 Boss 失联 |
| 5 | 心跳告警规则 + 飞书通知 | P1 | 1h | Boss 挂了需要主动通知 |
| 6 | Cluster Health 面板 | P2 | 1h | 长期趋势分析 |
| 7 | 环境变量化数据源地址 | P2 | 30min | 多集群兼容 |
| 8 | 锁定 Grafana 版本 | P2 | 5min | 避免 provisioning 格式变更 |
| 9 | Dashboard JSON 导出工作流 | P3 | 30min | 降低维护成本 |
| 10 | Prometheus + cadvisor 集成 | P4 | 2d | 需要新基础设施 |

---

## 11. Resource Estimates

| Resource | Size | Note |
|----------|------|------|
| `docs/infra/grafana/` (YAML) | ~20 KB | 纯文本，无存储成本 |
| Dashboard JSON per panel | 2-10 KB each | 随面板数线性增长 |
| Alerting rule YAML | 3-5 KB | 随规则数线性增长 |
| `deploy.sh` | < 1 KB | 固定大小 |
| Grafana storage (Volume) | ~100 MB | SQLite 数据库 + 面板缓存，当前已有 |

**Git 仓库影响**: 新增约 15-20 个文件，~150 KB 总大小。全部为文本文件，diff-friendly。

---

## 12. Conclusion

当前 Grafana 配置是**不可复现的**。数据源是手工创建的，面板不存在，告警不存在。这个问题不修复，每次容器重建都要重新配置，而且没有版本控制。

推荐立即实施 **Phase 1**（目录结构 + datasource YAML + deploy.sh），当天内完成。Phase 2（面板）和 Phase 3（告警）可以并行推进。

关键收益：
- **可复现**: `git clone && ./deploy.sh` = 完整 provisioning
- **可审计**: git log 记录每一次配置变更
- **可巡检**: 面板可视化替代手工 SQL
- **可告警**: Boss 挂了自动通知飞书群

> **Status: RECOMMENDED (P0)**
> 建议立即实施 Phase 1，Phase 2/3 在 48 小时内完成。
