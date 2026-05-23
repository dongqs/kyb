---
decision: 稍后做
---

# Review D3: MCP 全流程可观测性

**设计文档**: `docs/infra/designs/mcp-observability.md`
**评审焦点**: MCP 日志

---

## 1. Summary

设计文档覆盖了 MCP 调用的基本可观测性需求（指标、告警、自愈），但在**日志侧几乎完全空白**。指标只回答"出问题了"，日志才回答"出了什么问题"。如果没有结构化的 MCP 日志，debug MCP 调用失败就像蒙眼修机器。

---

## 2. Missing: Logging Layer

文档没有定义任何日志相关的内容，而日志是可观测性的基石。

### 2.1 建议新增：日志采集点

| 事件 | 日志内容 |
|------|---------|
| `mcp.call.start` | tool, server, params_size, request_id, timestamp |
| `mcp.call.end` | status, latency_ms, output_size, request_id |
| `mcp.call.error` | error_type, error_message, request_id, server, tool |
| `mcp.transport.reconnect` | retry_count, backoff_ms, server |
| `mcp.transport.disconnect` | reason, server, connection_duration_s |
| `mcp.server.heartbeat` | server, status, uptime_s |

### 2.2 建议新增：日志格式

采用结构化 JSON 日志，每行一个事件，兼容 Vector + ClickHouse 消费：

```json
{
  "timestamp": "2026-05-23T10:00:00.123Z",
  "level": "info",
  "event": "mcp.call.start",
  "request_id": "mcp-req-abc123",
  "server": "filesystem",
  "tool": "read_file",
  "params_size": 256,
  "session_id": "sess-xyz"
}
```

字段规范：
- `timestamp`: RFC3339 纳秒精度
- `level`: debug | info | warn | error
- `event`: 点号分隔的事件名（见 2.1）
- `request_id`: 每个 MCP 调用的唯一 ID，用于关联 start/end/error
- `session_id`: Claude Code 会话 ID，跨调用关联

### 2.3 建议新增：日志采集架构

```
MCP Server
  └─ stdout/stderr (JSON lines)
       └─ Vector (容器内 sidecar 或 host agent)
            ├─ ClickHouse (存储，7 天 retention)
            └─ 告警 (error 事件直接触达)
```

Vector 配置要点：
- source: `file` 或 `journald`，tail MCP Server 容器日志
- parser: `json`，解析结构化日志
- sink: `clickhouse`，写入 `mcp_logs` 表
- transform: 对 `level=error` 事件附加告警路由

### 2.4 建议新增：ClickHouse 表定义

```sql
CREATE TABLE infra.mcp_logs (
  timestamp DateTime64(3),
  level LowCardinality(String),
  event String,
  request_id String,
  server String,
  tool String,
  params_size UInt32,
  output_size UInt32,
  latency_ms UInt32,
  error_type String,
  error_message String,
  retry_count UInt8,
  backoff_ms UInt32,
  session_id String,
  raw_json String
) ENGINE = MergeTree()
ORDER BY (server, timestamp);
```

## 3. Missing: Trace Correlation

文档定义了 `request_id` 等指标 label，但没有说明如何跨组件关联：

- 建议：`request_id` 由 Claude Code 生成并传给 MCP Server，Server 原样带回
- 建议：`session_id` 由 Claude Code 生成，写入每行日志，用于按会话维度聚合
- 建议：日志中的 `request_id` 与指标中的 `request_id` tag 一致，实现 logs ↔ metrics 互跳

## 4. Issues

### 4.1 指标命名不一致

文档使用 `mcp_errors_total` 和 `mcp_retries_total` 两个 counter，但错误和重试在语义上有重叠——每次重试必然伴随一次错误。建议明确：
- `mcp_errors_total`: 记录所有错误（含导致重试的）
- `mcp_retries_total`: 仅记录重试动作本身，label 加 `error_type` 区分重试原因

### 4.2 告警盲区

- P0 `server_down > 30s` 缺乏日志侧支撑——光有告警没有对应日志，排障第一件事就是去查日志
- 建议：P0 告警触发时**自动附带最近 5 分钟的 error 日志摘要**

### 4.3 自愈没有观测

文档提到 Claude Code 内置指数退避和 fallback，但没有记录自愈过程：
- 建议：每次退避和 fallback 都写一行 `mcp.transport.backoff` / `mcp.tool.fallback` 日志
- 这样事后可以分析：自愈是否真的生效了，还是反复失败浪费了几十秒

## 5. Positive

- 指标选择合理（requests_total, latency histogram, error counter, server up gauge）
- 告警分级清晰（P0/P1/P2 按 severity 和 duration 分级）
- 自愈策略记录完整（退避参数、fallback 机制）
- 作为起步文档，架构成型，实施路线精简

## 6. Recommended Priority

| 项目 | 优先级 | 原因 |
|------|--------|------|
| 结构化日志 | P0 | 没有日志无法 debug |
| ClickHouse 表 + Vector 采集 | P0 | 日志需要存储和传输 |
| logs↔metrics 关联 | P1 | 排障效率加倍 |
| 自愈日志 | P1 | 确认自愈是否真的 work |
| 告警附带日志 | P2 | 锦上添花 |

---

**结论**: 设计方向正确，但日志是盲区。建议补齐日志层后再上生产，否则 MCP 故障就是黑盒子。
