---
decision: 稍后做
---

# cc-connect 消息全量入 ClickHouse

## 背景

cc-connect 处理的所有飞书消息（入站 + 出站）目前无持久化存储，历史不可查。运营同学无法回溯问题、分析用户活跃度或监控 token 消耗趋势。本方案将每条消息的结构化日志通过 Vector 采集进入 ClickHouse，并在 Grafana 中提供可视化面板。

## 采集链路

```
cc-connect (docker logs stdout)
    │
    ▼
Vector 容器 (sidecar / 独立容器)
    │  (原生 ClickHouse sink)
    ▼
ClickHouse (cc.message_log)
    │
    ▼
Grafana (ClickHouse datasource)
```

### 组件职责

| 组件 | 职责 |
|------|------|
| cc-connect | 以 JSON 格式输出结构化日志到 stdout（每行一条消息记录） |
| Vector | 监听 cc-connect 的 docker logs，解析 JSON，批量写入 ClickHouse |
| ClickHouse | 存储消息日志，提供高效的时间范围查询与聚合分析 |
| Grafana | 连接 ClickHouse 数据源，提供运营面板 |

### 部署说明

Vector 以独立容器方式运行，与 cc-connect 部署在同一台机器上。通过 Docker 日志驱动采集（`docker logs` 或直接挂载日志文件）。Vector 配置中指定 ClickHouse sink，写入 `cc.message_log` 表。

## 采集数据

每条消息采集以下字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `event_time` | DateTime64(3) | 事件发生时间（毫秒精度） |
| `event_type` | LowCardinality(String) | 事件类型：`message_received` / `message_sent` |
| `trace_id` | String | 全链路追踪 ID |
| `message_id` | String | 飞书消息 ID |
| `chat_id` | String | 聊天 ID（群聊或单聊） |
| `chat_type` | LowCardinality(String) | 聊天类型：`group` / `p2p` |
| `sender_id` | String | 发送者 ID（飞书 open_id 或 user_id） |
| `sender_type` | LowCardinality(String) | 发送者类型：`user` / `bot` / `system` |
| `message_type` | LowCardinality(String) | 消息类型：`text` / `image` / `post` / `interactive` / `system` |
| `content_text` | String | 消息文本内容（富文本取纯文本） |
| `content_len` | UInt32 | 消息文本长度（字符数） |
| `has_images` | UInt8 | 是否包含图片（0/1） |
| `session` | String | 会话标识 |
| `agent_session` | String | Agent 会话 ID |
| `response_len` | UInt32 | 出站消息长度（仅出站） |
| `turn_duration` | Float64 | 单轮响应耗时（秒，仅出站） |
| `input_tokens` | UInt32 | 入站消息 token 数（仅出站） |
| `output_tokens` | UInt32 | 出站消息 token 数（仅出站） |
| `tools_used` | UInt8 | 工具调用次数（仅出站） |

## 表结构

```sql
CREATE TABLE cc.message_log (
    event_time      DateTime64(3),
    event_type      LowCardinality(String),
    trace_id        String,
    message_id      String,
    chat_id         String,
    chat_type       LowCardinality(String),
    sender_id       String,
    sender_type     LowCardinality(String),
    message_type    LowCardinality(String),
    content_text    String,
    content_len     UInt32,
    has_images      UInt8,
    session         String,
    agent_session   String,
    response_len    UInt32,
    turn_duration   Float64,
    input_tokens    UInt32,
    output_tokens   UInt32,
    tools_used      UInt8
) ENGINE = MergeTree
ORDER BY (event_time, trace_id)
TTL event_time + INTERVAL 90 DAY
```

### 设计说明

- **排序键** `(event_time, trace_id)`：覆盖绝大多数时间范围查询和单条追踪查询。
- **TTL 90 天**：历史窗口 3 个月，超过自动删除，无需手动清理。
- **LowCardinality**：`event_type`、`chat_type`、`sender_type`、`message_type` 基数低，使用 LowCardinality 提升压缩比和查询性能。
- **毫秒精度时间**：`DateTime64(3)` 足以区分连续消息，且兼容 JSON 中的 ISO-8601 带毫秒格式。

## Grafana 面板

配置 ClickHouse 数据源后，创建以下面板：

### 1. 消息概览（Time Series）
- 指标：按 `event_type` 分组计数
- 粒度：1 分钟聚合
- 用途：观察入站/出站消息量趋势，发现异常突增或突降

### 2. 响应延迟热力图（Heatmap）
- 指标：`turn_duration` 分桶（0-1s, 1-5s, 5-15s, 15-30s, 30-60s, >60s）
- 展示：P50 / P90 / P99 时间序列叠加
- 用途：定位响应慢的时段，辅助排查性能问题

### 3. 用户活跃度 Top-N（Bar Chart / Table）
- 指标：按 `sender_id` 分组，统计消息数
- 排序：降序取 Top 20
- 用途：识别高频用户，辅助运营决策

### 4. Token 消耗堆叠面积图（Stacked Area）
- 指标：`input_tokens` + `output_tokens` 分别堆叠
- 粒度：1 小时聚合
- 用途：监控 LLM 调用成本趋势

### 5. 最近消息表格（Table）
- 显示：event_time, event_type, sender_id, content_text(截断), turn_duration, tokens
- 排序：按 event_time 降序
- 用途：快速查看最近消息，排查问题

## 资源估算

| 项目 | 数值 |
|------|------|
| 单条消息大小 | ~380 字节（压缩前） |
| 日均消息量 | ~90 条（估算） |
| 日均数据量 | ~34 KB（压缩前） |
| 90 天总量 | ~3 MB |
| ClickHouse 压缩比 | ~5-8x（LowCardinality + 列存） |
| 实际存储 | < 1 MB |

数据量极小，ClickHouse 几乎无感知。无需分区（按 TTL 自动淘汰即可），使用单表单分片即可满足需求。

## 查询示例

### 过去 24 小时消息量

```sql
SELECT event_type, count() AS cnt
FROM cc.message_log
WHERE event_time >= now() - INTERVAL 1 DAY
GROUP BY event_type
ORDER BY cnt DESC
```

### P99 响应延迟

```sql
SELECT toStartOfMinute(event_time) AS ts,
       quantile(0.99)(turn_duration) AS p99
FROM cc.message_log
WHERE event_type = 'message_sent'
  AND event_time >= now() - INTERVAL 1 DAY
GROUP BY ts
ORDER BY ts
```

### 用户活跃度 Top-10

```sql
SELECT sender_id, count() AS msg_cnt
FROM cc.message_log
WHERE event_time >= now() - INTERVAL 7 DAY
GROUP BY sender_id
ORDER BY msg_cnt DESC
LIMIT 10
```
