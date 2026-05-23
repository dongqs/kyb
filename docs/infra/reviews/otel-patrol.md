---
decision: 稍微有点不确定等专家再审一轮
---

# OTel Patrol: 巡检系统全链路追踪设计

**Author:** Boss
**File:** `docs/infra/reviews/otel-patrol.md`
**Status:** Draft

## 1. 概述

为 5 分钟巡检系统（`docs/infra/5min-patrol-guide.md`）引入 OpenTelemetry 分布式追踪。
每轮巡检（dispatch → check → heartbeat → report）输出一条完整 trace，实现：

- 巡检失败时快速定位断在哪个环节（没 dispatch 出去？check 卡住了？heartbeat 没写进去？report 没发出来？）
- 聚合多轮巡检数据，识别慢性病（disk 持续增长、sibling 反复死、check 越来越慢）
- 告警关联 trace_id，从 "又挂了" 到 "挂在哪一步"

## 2. Trace 模型

### 2.1 概览

每条 trace 对应 **一轮完整巡检**。四个阶段是顺序的，一个阶段失败则后续阶段跳过（或降级），但根 span 始终闭合：

```
patrol.round                                  (root, duration = 全流程)
├── patrol.dispatch                           (谁发的？发了没？)
├── patrol.check                              (环境检查：docker/disk/network/health)
│   ├── patrol.check.docker                   ├── 容器列表
│   ├── patrol.check.disk                     ├── 磁盘用量
│   ├── patrol.check.network                  ├── GitHub/GitLab 是否可达
│   └── patrol.check.health                   └── cc-healthcheck 结果
├── patrol.heartbeat                          (心跳写入 + 兄弟检查)
└── patrol.report                             (结果汇报：飞书 or 静默)
```

### 2.2 Span 定义

所有 span 使用 OTel semantic conventions 扩展，属性名遵循 `patrol.*` 命名空间。

#### 根 span: `patrol.round`

| 属性 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `patrol.round.id` | string | 本轮巡检 UUID | `"patr_01J2AB..."` |
| `patrol.round.number` | int | 闹钟编号 (1-3) | `1` |
| `patrol.round.agent_id` | string | 执行 agent 标识 | `"boss-claude-1"` |
| `patrol.round.team` | string | 所属团队 | `"kyb-infra"` |
| `patrol.round.status` | string | 最终状态 | `ok` / `partial` / `failed` |
| `patrol.round.error` | string | 失败原因（如有） | `"dispatch_timeout"` |

状态机：
- `ok` — 四步全部完成，无异常
- `partial` — 全部完成，但有 anomaly（sibling dead、disk > 85%）
- `failed` — 某一步挂了，没有完整执行

#### Span: `patrol.dispatch`

| 属性 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `patrol.dispatch.trigger` | string | 触发方式 | `cron` / `manual` / `recovery` |
| `patrol.dispatch.agent` | string | 被调度 agent | `"boss-claude-1"` |
| `patrol.dispatch.targets` | string[] | 巡检目标列表 | `["docker","disk","network","health"]` |
| `patrol.dispatch.timeout_ms` | int | 超时时间 | `300000` |
| `patrol.dispatch.status` | string | 调度结果 | `success` / `timeout` / `no_agent` |

#### Span: `patrol.check`

| 属性 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `patrol.check.checks_count` | int | 执行检查项数 | `4` |
| `patrol.check.checks_passed` | int | 通过数 | `3` |
| `patrol.check.checks_failed` | int | 失败数 | `1` |

##### 子 span: `patrol.check.docker`

| 属性 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `docker.containers_running` | int | 运行中容器数 | `12` |
| `docker.containers_expected` | int | 期望容器数 | `12` |
| `docker.containers_dead` | int | 异常容器数 | `0` |
| `docker.containers_missing` | string[] | 缺失容器名列表 | `[]` |

##### 子 span: `patrol.check.disk`

| 属性 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `disk.usage_percent` | float | 磁盘使用率 | `72.3` |
| `disk.available_bytes` | int | 可用字节 | `10737418240` |
| `disk.total_bytes` | int | 总字节 | `53687091200` |
| `disk.mount_point` | string | 挂载点 | `"/"` |

##### 子 span: `patrol.check.network`

| 属性 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `network.github.reachable` | bool | GitHub 可达 | `true` |
| `network.gitlab.reachable` | bool | GitLab 可达 | `true` |
| `network.latency_ms` | float | 测速延迟 | `123.4` |
| `network.proxy_active` | bool | 代理是否生效 | `true` |

##### 子 span: `patrol.check.health`

| 属性 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `healthcheck.status` | string | 健康检查结果 | `ok` / `restarted` / `error` |
| `healthcheck.restart_count` | int | 本次启动后重启次数 | `0` |
| `healthcheck.last_restart_reason` | string | 上次重启原因 | `"OOM"` |
| `healthcheck.token_valid` | bool | 飞书 token 有效 | `true` |

#### Span: `patrol.heartbeat`

| 属性 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `heartbeat.file` | string | 心跳文件路径 | `".kyb-diaries/.patrol-1-hb"` |
| `heartbeat.siblings_checked` | int | 检查的兄弟数 | `2` |
| `heartbeat.siblings_alive` | int | 存活兄弟数 | `2` |
| `heartbeat.siblings_dead` | int | 死亡兄弟数 | `0` |
| `heartbeat.dead_siblings` | string[] | 死亡兄弟名单 | `[]` |
| `heartbeat.oldest_alive_age_seconds` | float | 最旧心跳距今秒数 | `240.0` |
| `heartbeat.write_success` | bool | 心跳写入成功 | `true` |

**事件 (Event)**:

当检测到兄弟失联时，在 `patrol.heartbeat` span 上记录 event：

| Event name | 属性 | 说明 |
|-----------|------|------|
| `patrol.heartbeat.stale` | `sibling_id`, `age_seconds` | 兄弟心跳过期 |
| `patrol.heartbeat.dead` | `sibling_id`, `last_seen` | 兄弟判定死亡 |

#### Span: `patrol.report`

| 属性 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `report.anomaly_count` | int | 异常数 | `1` |
| `report.anomaly_list` | string[] | 异常描述列表 | `["sibling-2 heartbeat expired"]` |
| `report.severity` | string | 最高严重级别 | `info` / `warning` / `critical` |
| `report.notification.method` | string | 通知方式 | `feishu` / `none` |
| `report.notification.channel` | string | 通知渠道 | `"kyb-kindergarden"` |
| `report.notification.success` | bool | 通知发送成功 | `true` |
| `report.diary_written` | bool | 日记已写入 | `true` |

**事件**:

| Event name | 属性 | 说明 |
|-----------|------|------|
| `patrol.anomaly.detected` | `severity`, `component`, `message` | 检测到异常 |
| `patrol.notification.failed` | `method`, `channel`, `error` | 通知发送失败 |

### 2.3 Trace 示例

```json
{
  "trace_id": "0x1234...",
  "span_id": "0xaaaa...",
  "name": "patrol.round",
  "kind": "Internal",
  "start_time": "2026-05-23T12:00:00Z",
  "end_time": "2026-05-23T12:00:35Z",
  "attributes": {
    "patrol.round.id": "patr_01J2AB...",
    "patrol.round.number": 1,
    "patrol.round.agent_id": "boss-claude-1",
    "patrol.round.status": "partial"
  },
  "child_spans": [
    {
      "name": "patrol.dispatch",
      "duration_ms": 150,
      "attributes": {
        "patrol.dispatch.trigger": "cron",
        "patrol.dispatch.status": "success"
      }
    },
    {
      "name": "patrol.check",
      "duration_ms": 15000,
      "attributes": {
        "patrol.check.checks_passed": 3,
        "patrol.check.checks_failed": 0
      },
      "child_spans": [
        {
          "name": "patrol.check.docker",
          "duration_ms": 2000,
          "attributes": { "docker.containers_running": 12 }
        },
        {
          "name": "patrol.check.disk",
          "duration_ms": 500,
          "attributes": { "disk.usage_percent": 72.3 }
        },
        {
          "name": "patrol.check.network",
          "duration_ms": 8000,
          "attributes": { "network.latency_ms": 123.4 }
        },
        {
          "name": "patrol.check.health",
          "duration_ms": 1000,
          "attributes": { "healthcheck.status": "ok" }
        }
      ]
    },
    {
      "name": "patrol.heartbeat",
      "duration_ms": 500,
      "attributes": {
        "heartbeat.siblings_alive": 1,
        "heartbeat.siblings_dead": 1,
        "heartbeat.dead_siblings": ["boss-claude-2"]
      },
      "events": [
        {
          "name": "patrol.heartbeat.dead",
          "timestamp": "2026-05-23T12:00:27Z",
          "attributes": {
            "sibling_id": "boss-claude-2",
            "last_seen": "2026-05-23T11:44:00Z"
          }
        }
      ]
    },
    {
      "name": "patrol.report",
      "duration_ms": 3000,
      "attributes": {
        "report.anomaly_count": 1,
        "report.severity": "warning",
        "report.notification.success": true,
        "report.diary_written": true
      },
      "events": [
        {
          "name": "patrol.anomaly.detected",
          "attributes": {
            "severity": "warning",
            "component": "sibling",
            "message": "boss-claude-2 heartbeat expired (last seen 12:44, now 12:00)"
          }
        }
      ]
    }
  ]
}
```

## 3. 上下文传播

巡检系统基于 shell 脚本（`~/.kyb/bin/cc-healthcheck`）和自然语言指令（agent prompt），
因此 **trace context 通过文件系统传递**，而非传统的 W3C TraceContext HTTP header。

### 3.1 机制

```
步骤                         传递方式
─────────────────────────────────────────────────────
dispatch →                   boss 生成 trace_id + span_id
                            写入环境变量或临时文件
                            ⬇
check →                      agent 读取 trace_id，创建子 span
                            每个 check 子步骤继承
                            ⬇
heartbeat →                  agent 继续传递 trace_id
                            兄弟检查结果附在当前 span
                            ⬇
report →                     agent 闭合所有 span
                            通过 OTLP file exporter 写出
```

### 3.2 实现方式

对 shell 脚本场景，使用 **OTLP File Exporter**（beta）：

```bash
# 初始化 trace
export OTEL_TRACE_ID=$(uuidgen | tr -d '-')
export OTEL_SPAN_ID=$(openssl rand -hex 8)
export OTEL_SERVICE_NAME="patron"

# 写入 span 到 JSON Lines 文件
echo '{"trace_id":"'$OTEL_TRACE_ID'","name":"patrol.dispatch","timestamp":'$(date +%s%N)',"attributes":{...}}' \
  >> /tmp/otel-traces.jsonl
```

agent prompt 模板中嵌入 OTel 指令：

> You are running patrol round {number}. Your trace_id is {trace_id}.
> At each step (dispatch, check, heartbeat, report), record:
> - span name, start/end timestamps
> - key attributes (see: docs/infra/reviews/otel-patrol.md)
> On failure, record error attributes before aborting.

### 3.3 批量导出

使用 Vector 的 `file_source` 采集 `/tmp/otel-traces.jsonl`，经 `otlp` transform 转标准格式，
写入 ClickHouse（`otel.traces` 表）或转发到 OTLP collector。

```toml
# vector.toml 片段
[sources.patrol_traces]
type = "file"
include = ["/tmp/otel-traces.jsonl"]

[transforms.otel_normalize]
type = "remap"
inputs = ["patrol_traces"]
source = '''
  . = parse_json!(.message)
  .timestamp = parse_timestamp!(.timestamp, "%s%N")
'''

[sinks.clickhouse_traces]
type = "clickhouse"
inputs = ["otel_normalize"]
table = "otel.traces"
```

## 4. 派生指标

从 traces 通过 [OpenTelemetry SpanMetrics Connector](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector) 或 Prometheus `span_metrics` 规则派生。

### 4.1 Service-level 指标

| 指标名 | 类型 | 来源 | 维度 |
|--------|------|------|------|
| `patrol.rounds.total` | counter | `patrol.round` | status, number |
| `patrol.round.failures_total` | counter | `patrol.round{status=failed}` | error |
| `patrol.round.duration_seconds` | histogram | `patrol.round` end-start | status |
| `patrol.round.anomalies_total` | counter | `patrol.anomaly.detected` event count | severity |
| `patrol.round.checks_failed_total` | counter | `patrol.check.checks_failed` | check_type |

### 4.2 Component-level 指标

| 指标名 | 类型 | 来源 | 维度 |
|--------|------|------|------|
| `patrol.check.duration_seconds` | histogram | `patrol.check.{docker,disk,network,health}` | check_type |
| `patrol.check.disk.usage_percent` | gauge | `patrol.check.disk` → `disk.usage_percent` | mount_point |
| `patrol.check.docker.dead_containers` | gauge | `patrol.check.docker` → `docker.containers_dead` | — |
| `patrol.heartbeat.sibling_deaths_total` | counter | `patrol.heartbeat.dead` event | sibling_id |
| `patrol.report.notification_failures_total` | counter | `patrol.notification.failed` event | channel |
| `patrol.report.anomalies_by_severity` | gauge | `patrol.anomaly.detected` 事件计数 | severity |

### 4.3 已知问题

- **File exporter 无原生上下文关联**：agent 需手动传递 trace_id + parent_span_id，否则子 span 无法关联到根 span。解决方案：每个 check 子脚本接收 `OTEL_TRACE_ID` + `OTEL_PARENT_SPAN_ID` 环境变量。
- **时间戳精度**：shell `date +%s%N` 精度为纳秒，但 agent 的 clock skew 可能导致子 span 出现在父 span 之前。需要在根 span 创建时记基准时间，子 span 偏移量计算。
- **自动导出延迟**：Vector 采集有 `max_read_bytes` 和 `poll_interval` 配置，紧急 trace 可能延迟数秒。不影响调试（事后分析），但对实时告警有影响。

## 5. 告警规则

基于派生指标的 Prometheus 告警规则：

| 规则 | 表达式 | 级别 | 说明 |
|------|--------|------|------|
| NoPatrolCompleted | `rate(patrol_rounds_total{status="ok"}[6m]) == 0` | P0 | 超过 6 分钟没成功的巡检 |
| ConsecutiveFailures | `patrol_round_failures_total offset 5m > 0` | P1 | 连续两轮失败 |
| SiblingDead | `increase(patrol_heartbeat_sibling_deaths_total[10m]) > 0` | P1 | 有兄弟心跳丢失 |
| DiskNearFull | `patrol_check_disk_usage_percent > 85` | P2 | 磁盘接近打满 |
| NetworkBreach | `patrol_check_network_reachable{target="gitlab"} == 0` | P1 | GitLab 不可达 |

## 6. 实施路线

### Phase 1: 手动埋点 (1 天)
- [ ] 修改 `cc-healthcheck` 和 patrol prompt，嵌入 OTel trace 指令
- [ ] 输出 JSON Lines 到 `/tmp/otel-traces.jsonl`
- [ ] 人工验证一条完整 trace 的结构

### Phase 2: 采集管道 (0.5 天)
- [ ] 配置 Vector file_source → ClickHouse `otel.traces` 表
- [ ] 确认 trace 数据落入 CK

### Phase 3: 派生指标 + 告警 (0.5 天)
- [ ] 配置 spanmetrics connector 或 Prometheus recording rules
- [ ] 部署告警规则到 AlertManager
- [ ] 跑一轮巡检确认告警触发

## 7. 回退方案

如果 OTel File Exporter 在 shell 环境中过于脆弱，备选方案：
- **直接写 CK**: 每一段 span 直接 `clickhouse-client --query "INSERT INTO otel.traces ..."`
- **Vector exec source**: Vector 通过 `exec` source 定期执行 shell 脚本收集 trace
- **日志关联**: 不生成独立 trace，而是在每个 patrol 日志行中打印 `trace_id=xxx`，事后通过日志聚合还原

