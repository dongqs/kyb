# DeepSeek API 代理深化设计

> Issue: https://git.leyantech.com/quick-n-dirty/kyb/-/issues/169
> Status: Phase 0 — 设计方案审查
> 等级: **META-INFRA**（出问题 = 所有人断网）
>
> **铁律：本设计方案在 10 人审查通过前，任何人不得写任何代码。**

---

## 1. 代理核心设计

### 1.1 方案选择回顾

Issue #169 经过 4 轮审查（集成审查、全栈审查、基础设施架构审查、闭环控制审查），一致推荐 **方案 E（手搓反向代理）**。核心结论：

- **方案 A（MITM 代理）** — 放弃。E 覆盖了 A 的所有应用层能力，且无需 TLS MITM
- **方案 B（sing-box mirror）** — 必选副产物。零成本获取调用频率/延迟/连接健康度
- **方案 C（Claude Plugin Hook）** — 备选。仅覆盖 Claude Code 场景，不覆盖 curl/其他工具
- **方案 D（DeepSeek 日志 API）** — 放弃。核心需求（prompt + completion 内容）不可满足
- **方案 E（手搓反向代理）** — **主方案**。Complexity 最低，ROI 最高

### 1.2 编程语言选择

| 维度 | Go | Ruby (Sinatra) | Python (Flask/FastAPI) |
|------|:--:|:--------------:|:---------------------:|
| 并发模型 | 原生 goroutine | 需要 Gunicorn/Puma 多进程 | GIL 受限，需 async/await |
| 标准库 HTTP | net/http 完整 | Rack 标准 | WSGI/ASGI |
| SSE 处理 | bufio.Scanner 逐行读取 | Rack hijack 或 EventSource | StreamingResponse |
| 连接池 | 内置，默认复用 | 需显式配置(persistent) | requests.Session / httpx |
| CK 异步写入 | goroutine + channel buffer | Sidekiq/Thread 或 fork | asyncio / multiprocessing |
| 可部署性 | 单二进制 | 需 Ruby runtime | 需 Python runtime |
| kyb 技术栈契合 | 否（kyb 是 Ruby 项目） | **是** | 否 |
| 错误处理成熟度 | 好 | 好 | 好 |
| 编译/部署开销 | 零（静态编译） | 需 bundle + runtime | 需 pip + runtime |

**结论：选择 Go。**

理由：

1. **关键路径上需要确定性延迟** — Go 的 goroutine 提供可预测的并发性能，不会出现 Ruby GIL 下的请求排队。对于 meta-infra 级别的代理，延迟稳定性优于一切。
2. **单二进制部署** — 无需 Ruby runtime、无需 bundle install、无需管理 gem 版本。一个 `go build` 产出的二进制文件复制到容器即可运行。减少部署的故障点。
3. **内置连接池** — `http.Transport` 默认启用 keep-alive 和连接池，对 DeepSeek 的 TLS 连接会自动复用。Ruby 的 `net/http` 默认不启用 persistent——忘记配就是性能灾难。
4. **goroutine + channel 的异步模式** — CK 写入天然适合异步 buffer 模式：`goroutine` 负责接收 CK 写入请求，`channel` 做 buffer，`batch insert` 每 100ms 刷一次。Ruby 的 `Thread` + `Queue` 也能做到，但 Go 的 goroutine 在此场景下更安全（goroutine panic 只杀死自身不杀进程）。
5. **Streaming 处理的成熟度** — Go 的 `bufio.Scanner` 处理 SSE 的 `Scan()` + `Bytes()` 模式是标准做法，大量生产验证。Ruby 的 `rack.hijack` API 使用少，边缘场景多。

否决 Ruby 和 Python 的核心理由：此组件是 **meta-infra 级别**，不能有任何 runtime 依赖或 GC pause 导致的不可预测延迟。Go 的静态编译 + 精确内存控制 + 成熟并发模型，是最低风险的选择。

### 1.3 架构与请求/响应流向

```
┌─────────────────────────────────────────────────────────────┐
│ Claude Agent Container                                       │
│  ANTHROPIC_BASE_URL=http://kyb-infra-api-proxy:2082         │
│  (HTTP 明文, Docker 内部网络)                                │
└────────────────────┬────────────────────────────────────────┘
                     │ POST /v1/messages
                     │ (JSON body: model, messages, stream=true/false)
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ kyb-infra-api-proxy (:2082)                                   │
│                                                               │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │ Receive      │───▶│ Log Request  │───▶│ Forward to   │   │
│  │ Handler      │    │ (async CK)   │    │ DeepSeek     │   │
│  └──────────────┘    └──────────────┘    └──────┬───────┘   │
│                                                  │           │
│  ┌──────────────┐    ┌──────────────┐           │           │
│  │ Return to    │◀───│ Log Response │◀──────────┘           │
│  │ Claude       │    │ (async CK)   │                       │
│  └──────────────┘    └──────────────┘                       │
│                                                               │
│  ┌──────────────┐                                           │
│  │ Health Check │  :2082/healthz                            │
│  │ (every 30s)  │  :2082/readiness                          │
│  └──────────────┘                                           │
└────────────────────┬────────────────────────────────────────┘
                     │ HTTPS (原始 TLS)
                     │ api.deepseek.com/anthropic/v1/messages
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ api.deepseek.com                                              │
│ Anthropic 兼容接口                                             │
└─────────────────────────────────────────────────────────────┘

                         ╔══════════════════╗
                         ║   ClickHouse     ║
                         ║  infra.api_logs  ║
                         ║  (异步批量写入)   ║
                         ╚══════════════════╝
```

#### 核心流程（非 Streaming）

1. Claude 发送 HTTP POST `http://kyb-infra-api-proxy:2082/v1/messages`
2. 代理接收完整 request body，提取 `model`、`messages`、`stream` 字段
3. 异步写入 `infra.api_logs`（request_body, model, timestamp, api_key_prefix）
4. 代理转发请求到 `https://api.deepseek.com/anthropic/v1/messages`
   - 保留原始 HTTP headers（`Authorization`, `Content-Type`, `anthropic-version`）
   - 修改 `Host` 为 `api.deepseek.com`
   - 添加 `X-Request-Id` 用于追踪
5. DeepSeek 返回完整 JSON response
6. 代理读取完整 response body，提取 `usage`（prompt_tokens, completion_tokens）
7. 异步写入 `infra.api_logs`（UPDATE same row: response_body, usage, latency_ms, status_code）
8. 代理将 response 原样返回给 Claude

#### 核心流程（Streaming / SSE）

1. Claude 发送 HTTP POST `http://kyb-infra-api-proxy:2082/v1/messages`（`stream: true`）
2. 代理接收完整 request body，记录同上
3. 代理转发请求到 DeepSeek（同上）
4. DeepSeek 返回 `Transfer-Encoding: chunked` + `Content-Type: text/event-stream`
5. 代理逐行读取 SSE chunks
   - `event: message_start` → 记录起始时间（TTFT = now - start）
   - `event: content_block_delta` → 拼接 completion text
   - `event: message_delta` → 提取 usage（delta.usage）
   - `event: message_stop` → 标记 streaming 完成
   - `event: error` → 标记 error
6. 每收到一个 chunk，立即原样转发给 Claude（**零延迟透传**）
7. 在内存 buffer 中拼接 completion chunks
8. `message_stop` 事件后，异步写入 `infra.api_logs`（完整 response_body, usage, latency_ms, ttft_ms）

### 1.4 Streaming (SSE) 处理方案

#### 实现策略

采用 **逐 chunk 透传 + 内存拼接** 策略：

```
Claude                    Proxy                   DeepSeek
  │                         │                        │
  │  POST /v1/messages      │                        │
  │  (stream: true)         │                        │
  │────────────────────────▶│                        │
  │                         │  POST /v1/messages     │
  │                         │───────────────────────▶│
  │                         │                        │
  │                         │  event: message_start  │
  │                         │◀───────────────────────│
  │  event: message_start   │                        │
  │◀────────────────────────│                        │
  │                         │                        │
  │                         │  event: ping           │
  │                         │◀───────────────────────│
  │  event: ping            │                        │
  │◀────────────────────────│                        │
  │                         │                        │
  │                         │  event: content_block_ │
  │                         │  delta (chunk 1)       │
  │                         │◀───────────────────────│
  │  chunk 1                │                        │
  │◀────────────────────────│  (buffer chunk 1 in   │
  │                         │   memory, forward      │
  │                         │   immediately)         │
  │                         │                        │
  │                         │  event: content_block_ │
  │                         │  delta (chunk N)       │
  │                         │◀───────────────────────│
  │  chunk N                │                        │
  │◀────────────────────────│  (buffer chunk N)      │
  │                         │                        │
  │                         │  event: message_stop   │
  │                         │◀───────────────────────│
  │  event: message_stop    │                        │
  │◀────────────────────────│                        │
  │                         │                        │
  │                         │  async CK write:       │
  │                         │  - full completion     │
  │                         │  - usage               │
  │                         │  - latency_ms          │
  │                         │  - ttft_ms             │
  │                         │  - streaming=true      │
```

#### 关键设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 写入时机 | `message_stop` 后一次性写入 | Streaming 过程中无需写入 CK（数据不完整），减少 CK 写入次数 |
| 内存 buffer | 最多 2MB 或 5 分钟 | 防止超长 response 撑爆内存。超过限制后截断，标记 `truncated=true` |
| CK 写入延迟 | 增加 0ms（异步，不阻塞转发） | 转发和 CK 写入在两个独立 goroutine |
| 连接中断处理 | 已收到的 chunks 写入 CK，标记 `error=stream_interrupted` | 避免日志完全丢失 |
| Content-Type 检测 | 非 SSE 响应按非 streaming 流程处理 | 兼容 DeepSeek 可能返回的非 streaming fallback |

#### SSE 行解析器设计

```
收到 TCP chunk
    │
    ▼
逐行读取 (bufio.Scanner)
    │
    ├── 空行 (\n\n) → event 分隔符，忽略
    │
    ├── "event: " → 记录当前 event type
    │
    ├── "data: " → 读取 JSON payload
    │   ├── event=message_start:
    │   │   - 记录 ttft = now() - request_start_time
    │   │   - 保存 request_id, model
    │   │
    │   ├── event=content_block_delta:
    │   │   - delta.text 追加到 completion buffer
    │   │   - 立即转发给 Claude
    │   │
    │   ├── event=message_delta:
    │   │   - delta.usage.output_tokens 保存
    │   │   - stop_reason 保存
    │   │   - 立即转发
    │   │
    │   ├── event=message_stop:
    │   │   - 标记 streaming 完成
    │   │   - 触发 CK 异步写入
    │   │   - 立即转发
    │   │
    │   └── event=error:
    │       - 记录 error message
    │       - 标记 truncated=true
    │       - 触发 CK 写入（即使不完整）
    │
    └── 非 SSE 行 → 原样透传（兼容 DeepSeek 的非标准输出）
```

### 1.5 CK Schema 设计

```sql
-- infra.api_logs: DeepSeek API 请求/响应日志
-- ENGINE: MergeTree
-- PARTITION: toYYYYMM(timestamp)
-- TTL: 90 天

CREATE TABLE infra.api_logs (
    -- 时间
    timestamp           DateTime64(3)       CODEC(DoubleDelta, LZ4),
    
    -- 请求标识
    request_id          String,
    trace_id            String              DEFAULT '',         -- 与 claude_hook_events 关联的 trace
    
    -- 模型信息
    model               LowCardinality(String),
    
    -- 调用方
    api_key_prefix      FixedString(8)      DEFAULT '',         -- API key 前 8 位，用于区分用户
    client_ip           String              DEFAULT '',         -- 客户端 IP（Docker 内部则为容器名）
    source_container    String              DEFAULT '',         -- 来源容器名（Docker 内部网络环境）
    
    -- Token 用量（从 usage 中提取）
    prompt_tokens       UInt32              CODEC(T64, LZ4),
    completion_tokens   UInt32              CODEC(T64, LZ4),
    
    -- 性能指标
    latency_ms          UInt32              CODEC(T64, LZ4),    -- 总延迟（请求到最后一个 chunk）
    ttft_ms             UInt32              CODEC(T64, LZ4),    -- Time to first token（仅 streaming）
    
    -- 状态
    status_code         UInt16,                                 -- 200 / 502 / 504 等
    streaming           UInt8,                                  -- 0=非流式, 1=流式
    
    -- 内容（可截断）
    request_body        String              DEFAULT '',
    response_body       String              DEFAULT '',
    
    -- 截断与错误标记
    truncated           UInt8               DEFAULT 0,          -- 0=完整, 1=截断
    error               String              DEFAULT '',
    
    -- 附加元数据
    cached              UInt8               DEFAULT 0,          -- 请求是否命中 upstream cache（如果实现缓存）
    retry_count         UInt8               DEFAULT 0           -- 代理内部重试次数
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, model, status_code)
TTL timestamp + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

#### 设计说明

1. **ORDER BY `(timestamp, model, status_code)`** — 覆盖绝大多数查询场景：
   - 查某时间段的全部请求（timestamp 范围扫描）
   - 查某个 model 的用量（timestamp + model 前缀）
   - 查失败的请求（timestamp + status_code 前缀）

2. **TTL 90 天** — 与 `cc.message_log` 保持一致。历史会话回溯不需要超过 90 天。

3. **内容截断策略**：
   - `request_body` 超过 64KB → 存前 32KB + 后 32KB，中间 `... [truncated ...]`，标记 `truncated=1`
   - `response_body` 超过 128KB → 同上，但保留前后各 48KB。原因是 response 尾部有 usage 信息，不能丢
   - 截断在代理内存中完成，不增加下游负担

4. **`api_key_prefix`** — 只存前缀（`sk-xxxx1234` 的前 8 位），用于区分是哪个用户的 API key 发起的请求。不存完整 key。

5. **`source_container`** — 在 Docker 内部网络中，可以用容器名区分来源。如果代理被多个容器共用，可用于成本分摊。

6. **`ttft_ms`** — 仅 streaming 请求有意义。非 streaming 请求该字段为 0。

#### 索引与查询优化

```sql
-- 查询 1: 各 model 的 token 消耗（成本分析）
SELECT model,
       sum(prompt_tokens) AS total_prompt,
       sum(completion_tokens) AS total_completion,
       count() AS request_count
FROM infra.api_logs
WHERE timestamp >= now() - INTERVAL 1 DAY
GROUP BY model;

-- 查询 2: 错误率监控
SELECT toStartOfMinute(timestamp) AS ts,
       countIf(status_code >= 400) AS errors,
       count() AS total,
       round(errors / total * 100, 2) AS error_rate
FROM infra.api_logs
WHERE timestamp >= now() - INTERVAL 1 HOUR
GROUP BY ts
ORDER BY ts;

-- 查询 3: 延迟分布
SELECT model,
       quantiles(0.5, 0.9, 0.99)(latency_ms) AS latency_p50_p90_p99
FROM infra.api_logs
WHERE timestamp >= now() - INTERVAL 1 DAY
  AND status_code = 200
GROUP BY model;

-- 查询 4: 搜索特定内容的请求
SELECT timestamp, model, prompt_tokens, completion_tokens, latency_ms
FROM infra.api_logs
WHERE request_body LIKE '%specific_command%'
   OR response_body LIKE '%specific_keyword%'
ORDER BY timestamp DESC
LIMIT 20;

-- 查询 5: 按 API key 的用量审计
SELECT api_key_prefix,
       count() AS requests,
       sum(prompt_tokens) AS total_prompt,
       sum(completion_tokens) AS total_completion
FROM infra.api_logs
WHERE timestamp >= now() - INTERVAL 7 DAY
GROUP BY api_key_prefix
ORDER BY total_completion DESC;
```

### 1.6 错误处理策略

#### 转发层错误

| 错误类型 | 行为 | CK 记录 |
|----------|------|---------|
| DeepSeek 连接超时（10s） | 返回 504，Claude 侧自行重试 | status_code=504, error="upstream_timeout" |
| DeepSeek DNS 解析失败 | 返回 502 | status_code=502, error="dns_resolution_failed" |
| DeepSeek TLS 握手失败 | 返回 502 | status_code=502, error="tls_handshake_failed" |
| DeepSeek 返回 4xx（含 429） | 原样返回 Claude | status_code=实际值, error="" |
| DeepSeek 返回 5xx | 原样返回 Claude（不自动重试，避免重复日志） | status_code=实际值, error="" |
| DeepSeek 返回非法 body | 返回 502 | status_code=502, error="invalid_response_body" |
| SSE 解析错误 | 返回 502 | status_code=502, error="sse_parse_error" |

**关键原则：不要代替 Claude 做重试。** 重试决策在 Claude 侧（或上层业务逻辑），代理只做透传。代理侧的重试会导致重复日志，且与 Claude 侧的重试冲突。

#### CK 写入层错误

| 错误类型 | 行为 |
|----------|------|
| CK 连接失败 | 跳过写入，不阻塞响应。尝试写入本地 buffer（最多保留 1000 条），后续成功时补写 |
| CK 写入超时（2s） | 跳过写入。buffer 中的下批次继续尝试 |
| CK schema 不匹配 | 跳过写入，log error（不 crash） |
| CK 批量写入部分失败 | 重试 1 次失败的部分，重试失败则丢弃（不阻塞） |

**强制模式：Fail-open。CK 写入永远不能阻塞 Claude 的请求。**

#### 代理自身错误

| 错误类型 | 行为 |
|----------|------|
| goroutine panic | recover + log error，当前请求返回 500，代理持续运行 |
| 内存溢出（buffer > 2MB） | 截断 completion buffer，标记 `truncated=1`，继续转发 |
| 端口被占用 | 启动失败，systemd 自动重启 |
| 配置错误 | 启动失败，log error，systemd 重试上限 3 次后退出 |

---

## 2. 熔断与降级

### 2.1 熔断原理

代理作为关键路径上的组件，必须实现 **Circuit Breaker 模式**。熔断的目的是：**当代理或上游出问题时，自动切到直连 DeepSeek，不让 Claude 等响应**。

```
┌──────────────────────────────────────────────────────┐
│  Circuit Breaker 状态机                                │
│                                                        │
│       ┌──────────┐                                      │
│       │  CLOSED   │ ← 正常工作                           │
│       │  (正常)   │                                      │
│       └─────┬────┘                                      │
│             │ 连续 N 次失败                               │
│             ▼                                           │
│       ┌──────────┐                                      │
│       │   OPEN   │ ← 熔断开启，所有请求返回 fallback    │
│       │  (熔断)   │                                      │
│       └─────┬────┘                                      │
│             │ 超时后进入半开                              │
│             ▼                                           │
│       ┌──────────┐                                      │
│       │  HALF-   │ ← 放一个测试请求，成功则关闭         │
│       │  OPEN    │   失败则继续保持开启                  │
│       └──────────┘                                      │
└──────────────────────────────────────────────────────┘
```

### 2.2 健康检查机制

代理暴露两个健康检查端点：

| 端点 | 用途 | 检查内容 | 频率 |
|------|------|----------|------|
| `GET /healthz` | Liveness (存活) | 代理进程是否健康、goroutine pool 是否正常 | 30s |
| `GET /readiness` | Readiness (就绪) | 代理能否正常处理请求（含 CK 连接检测） | 30s |

#### `/healthz` 检查

```go
// 伪代码
func healthzHandler(w, r) {
    // 1. 检查 goroutine pool 状态
    // 2. 检查内存使用 < 256MB
    // 3. 检查 SSE buffer 总量 < 100MB
    // 4. 返回 200 OK + {"status": "healthy"}
}
```

#### `/readiness` 检查

```go
// 伪代码
func readinessHandler(w, r) {
    // 1. 调用 healthz 检查
    // 2. 尝试发送 test query 到 CK（超时 1s）
    // 3. 检查最近的转发成功率（过去 1 分钟的 200 比例）
    // 4. 全部通过 → 200 OK
    // 5. 任何一项失败 → 503 Service Unavailable
}
```

#### 内置健康巡检

代理内部有一个 **背景 goroutine**，每 10 秒做一次连乘探测：

```
内置巡检 (每 10s)
    │
    ├── 1. TCP connect → api.deepseek.com:443 (超时 3s)
    │   └── 失败 → connect_failure_count++
    │
    ├── 2. HTTP GET → api.deepseek.com (超时 5s)
    │   └── 非 200 → upstream_health_failure_count++
    │
    ├── 3. CK INSERT test (超时 1s)
    │   └── 失败 → ck_write_failure_count++
    │
    └── 所有检查结果更新到内存状态，供 `/readiness` 使用
```

### 2.3 熔断阈值

```
┌─────────────────────────────────────────────────────────────┐
│ 熔断配置                                                     │
├─────────────────────────────────────────────────────────────┤
│  failure_threshold:    3      # 连续失败次数 → OPEN         │
│  success_threshold:    2      # 半开后连续成功次数 → CLOSED │
│  half_open_timeout:    30s    # OPEN → HALF-OPEN 等待时间   │
│  max_half_open_retry:  3      # HALF-OPEN 最大重试次数       │
│  health_check_interval: 10s   # 内部巡检间隔                  │
├─────────────────────────────────────────────────────────────┤
│ 失败判定条件（满足任一即 +1）                                  │
├─────────────────────────────────────────────────────────────┤
│  1. 转发 DeepSeek 超时（>10s）                                │
│  2. DeepSeek 返回 502/503                                    │
│  3. SSE 解析错误                                              │
│  4. CK 连续 5 次写入失败（仅影响熔断决策，不阻塞请求）         │
└─────────────────────────────────────────────────────────────┘
```

#### 熔断状态切换

```
CLOSED → OPEN:  连续 3 次转发失败
OPEN → HALF-OPEN: 30 秒后自动进入
HALF-OPEN → CLOSED: 放行一个测试请求成功，再放行一个验证成功
HALF-OPEN → OPEN: 测试请求失败，计数器归零，等待 30s 后重试
```

#### 熔断触发后的行为

当熔断器进入 **OPEN** 状态时：

1. **代理层 fallback**：代理不再转发到 DeepSeek，而是返回一个特殊的 HTTP 响应给 Claude，指示 Claude 直接连接到 DeepSeek（通过响应 header）
2. **但代理仍响应对健康检查的请求**：`/healthz` 和 `/readiness` 始终可用
3. **熔断状态通过 `/readiness` 暴露**：返回 503 + `{"status": "open", "circuit_breaker": true}`

### 2.4 Fallback 到直连 DeepSeek

#### 方案 A：ANTHROPIC_BASE_URL 切换（推荐）

这是最彻底的 fallback：当代理熔断时，修改 Claude 的 `ANTHROPIC_BASE_URL` 跳过多层：

```
正常:   ANTHROPIC_BASE_URL=http://kyb-infra-api-proxy:2082
熔断:   ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic (直连)
恢复:   ANTHROPIC_BASE_URL=http://kyb-infra-api-proxy:2082 (重新切回)
```

**切换方式（按优先级）：**

| 优先级 | 方式 | 延迟 | 适用场景 |
|--------|------|------|----------|
| P0 | **配置中心/共享文件** — 代理写状态到共享文件，Claude 侧的 watch 进程检测到变化后修改 env | ~1s | 自动熔断 |
| P1 | **kyb 管理员手动执行** — `kyb infra proxy fallback --on / --off` | 手动 | 管理员干预 |
| P2 | **容器重建** — 修改 docker-compose env，重建 Claude 容器 | ~10s | 极端场景 |

#### 方案 B：代理返回 503，Claude 侧重试到直连（备选）

不修改 `ANTHROPIC_BASE_URL`，而是让 Claude Code 本身支持 fallback 配置。

但 Claude Code 原生不支持此能力。需要：
- 在 Claude 侧设置两个 URL：一个用代理，一个用直连
- 当代理返回 503 时自动切换到直连

**不推荐此方案。** 因为：
1. 需要修改 Claude Code 配置（不在 kyb 控制范围内）
2. Claude 侧切换有时间窗口，期间请求可能失败
3. 增加了复杂性，不如方案 A 直接

#### Fallback 时机决策流程

```
收到请求
    │
    ▼
熔断器状态？
    ├── CLOSED → 正常转发到 DeepSeek
    │
    ├── OPEN → 代理返回 502 + X-Fallback-URL header
    │         Claude 侧 watch 进程检测到 → 修改 ANTHROPIC_BASE_URL
    │         → 后续请求直连 DeepSeek
    │
    └── HALF-OPEN → 放行一个测试请求
        ├── 成功 → CLOSED（恢复正常）
        └── 失败 → OPEN（继续熔断）
```

#### 熔断恢复流程

```
代理启动 / 熔断恢复
    │
    ▼
1. 代理读取自身状态（共享文件或内存）
    ├── 上次是 OPEN → 进入 HALF-OPEN
    └── 上次是 CLOSED → 正常模式
    │
    ▼
2. 健康检查通过 → CLOSED
    │
    ▼
3. 通知外部：代理可用
    ├── 写入共享文件："proxy_healthy=true"
    └── 管理员手动切回：
        docker exec claude-container sh -c 'export ANTHROPIC_BASE_URL=http://kyb-infra-api-proxy:2082'
```

---

## 3. 测试方案

### 3.1 Mock DeepSeek Server 设计

在设计阶段不写测试代码，但测试方案的设计需要明确，以便后续 Phase 1 实现。

#### Mock Server 架构

```
┌─────────────────────────────────────────────────────────┐
│ Mock DeepSeek Server                                    │
│ Port: 18080 (Docker 内部)                                │
│                                                         │
│ 功能:                                                    │
│  - 模拟 api.deepseek.com/anthropic/v1/messages          │
│  - 支持非 streaming 响应（可配置延迟/状态码/body）        │
│  - 支持 streaming 响应（可配置 chunk 间隔/总 chunk 数）   │
│  - 可注入故障（断连/超时/乱序/invalid SSE）              │
│  - 记录收到的请求，用于验证                              │
│                                                         │
│ 配置接口:                                                │
│  POST /__admin/scenario → 设置响应场景                    │
│  GET  /__admin/requests  → 查看收到的请求                 │
│  POST /__admin/reset    → 重置所有状态                    │
└─────────────────────────────────────────────────────────┘
```

#### Mock Server 支持的场景

| 场景 ID | 描述 | 响应行为 |
|---------|------|----------|
| `happy_path_non_stream` | 正常非 streaming | 延迟 200ms，返回完整 JSON |
| `happy_path_stream` | 正常 streaming | 3 个 chunk，每个间隔 100ms |
| `empty_response` | 空响应 | 返回 200 + 空 body |
| `slow_response` | 慢响应 | 延迟 10s 后返回 |
| `timeout` | 连接超时 | 不响应，直到客户端超时 |
| `connection_reset` | 连接断开 | 接收请求后立即 reset |
| `http_429` | 限流 | 返回 429 + Retry-After header |
| `http_500` | 服务器错误 | 返回 500 |
| `http_503` | 服务不可用 | 返回 503 |
| `invalid_json` | 非法响应 | 返回 200 + 非法 JSON |
| `invalid_sse` | 非法 SSE 格式 | 返回 `event: unknown\n` + 非法 data |
| `partial_sse` | SSE 中途断开 | 发 2 个 chunk 后断开 |
| `huge_response` | 超大响应 | > 2MB response body |
| `stream_ordering` | 流式乱序 | 模拟罕见的 chunk 乱序场景 |

#### Mock Server 配置参数

```go
// 伪代码 — 仅描述接口，不写实现
type Scenario struct {
    ID              string           // 场景标识
    ResponseDelay   time.Duration    // 响应前延迟
    StatusCode      int              // HTTP 状态码
    Body            string           // 静态 body（非 streaming）
    SSEChunks       []SSEChunk       // streaming chunks（streaming 模式）
    ChunkInterval   time.Duration    // chunk 间隔
    ResetAfter      bool             // 发送后是否 reset 连接
    InjectError     string           // 注入错误类型
}
```

### 3.2 测试用例清单

#### 正常流程

| 编号 | 测试点 | 配置 | 预期 |
|------|--------|------|------|
| TC-01 | 非 streaming 请求成功 | Mock: happy_path_non_stream | 返回完整 JSON，CK 写入一条记录 |
| TC-02 | Streaming 请求成功 | Mock: happy_path_stream | 逐 chunk 转发，message_stop 后 CK 写入 |
| TC-03 | 空 messages 请求 | 空请求 body | 返回 200（DeepSeek 行为） |
| TC-04 | 多轮对话 | 含历史消息 | 正常转发和记录 |
| TC-05 | 超大 prompt（< 64KB） | 接近 64KB | 完整记录，truncated=0 |
| TC-06 | Streaming reasoning 模型 | 模拟 deepseek-reasoner | 含 reasoning_content 的 SSE |

#### 异常流程

| 编号 | 测试点 | 配置 | 预期 |
|------|--------|------|------|
| TC-07 | DeepSeek 返回 429 | Mock: http_429 | 原样返回 429 给 Claude |
| TC-08 | DeepSeek 返回 500 | Mock: http_500 | 原样返回 500，CK 记录 error |
| TC-09 | DeepSeek 超时（10s） | Mock: timeout | 代理返回 504 |
| TC-10 | DeepSeek 连接断开 | Mock: connection_reset | 代理返回 502 |
| TC-11 | DeepSeek 返回非法 JSON | Mock: invalid_json | 代理返回 502 |
| TC-12 | SSE 中非法 data | Mock: invalid_sse | 代理返回 502，CK 记录 error |
| TC-13 | SSE 中途断开 | Mock: partial_sse | 已收 chunks 写 CK，truncated=1 |
| TC-14 | CK 不可用 | 停掉 CK 容器 | 代理继续工作，CK 写入跳过 |

#### 边界条件

| 编号 | 测试点 | 配置 | 预期 |
|------|--------|------|------|
| TC-15 | 超大 response（> 2MB） | Mock: huge_response | body 截断，truncated=1 |
| TC-16 | 并发请求（100 个同时） | 随机分配 happy_path / slow | 全部正常完成，无排队堵塞 |
| TC-17 | 长连接复用 | 连续 50 个请求复用同一连接 | 连接池正常工作 |
| TC-18 | 多个不同 API key | 发请求时换 Authorization header | 正确记录 api_key_prefix |
| TC-19 | 空 Authorization header | 请求无 auth | 正常转发（DeepSeek 决定行为） |
| TC-20 | 熔断后恢复 | 触发 3 次失败 → 等待 30s → 发送成功请求 | 自动恢复 CLOSED |

### 3.3 Chaos Monkey 场景

设计阶段定义 chaos monkey 场景，实现阶段为这些场景编写 Go 测试框架。

#### 网络故障

| 场景 | 操作 | 观测点 |
|------|------|--------|
| **断网 10s** | `iptables -D OUTPUT -d api.deepseek.com -j DROP`，10s 后恢复 | 熔断器在 3 次失败后激活，fallback 切换 |
| **DNS 故障 30s** | 修改 `/etc/hosts` 删除 DeepSeek IP 或指向不可达 IP | DNS 解析失败 → 502，熔断激活 |
| **延迟抖动** | `tc qdisc add dev eth0 root netem delay 1000ms 500ms` | 延迟增加，但不断连。验证代理的超时处理 |
| **随机丢包 10%** | `tc qdisc add dev eth0 root netem loss 10%` | 部分请求失败，观测熔断阈值 |
| **带宽限制 100Kbps** | `tc qdisc add dev eth0 root tbf rate 100kbps burst 10k` | 响应变慢但不断连 |

#### CK 故障

| 场景 | 操作 | 观测点 |
|------|------|--------|
| CK 容器停止 | `docker stop clickhouse` | CK 写入失败 → 代理 Fail-open 继续工作 |
| CK 容器恢复 | `docker start clickhouse` | 代理自动恢复 CK 写入（无需重启） |
| CK 写入延迟 > 5s | CK 负载增加导致写入慢 | 代理的 CK 写入超时 2s，跳过写入，不阻塞响应 |

#### 代理自身故障

| 场景 | 操作 | 观测点 |
|------|------|--------|
| 代理 OOM | 发送超大 response，让 buffer 超限 | 截断机制生效，代理不 crash |
| 代理重启 | `docker restart kyb-infra-api-proxy` | 重启期间请求走 fallback，恢复后自动切回 |
| 端口冲突 | 启动另一个进程占用 :2082 | 代理启动失败，systemd 重试 |
| 时钟跳跃 | 系统时间突然变化 | 代理的 latency 计算不受影响（使用 monotonic clock） |

#### 综合压力测试

```
Chaos Scenario: "星期五下午"
- 模拟 50 个并发用户（每个发 20 个请求）
- 10% 概率 DeepSeek 返回 429
- 5% 概率 DeepSeek 超时
- 5% 概率 CK 写入慢
- 持续 5 分钟

验证目标：
1. 所有请求最终被回应（成功或适当错误码）
2. 熔断器不误触发（非全局故障不触发熔断）
3. CK 日志不丢失（除写入失败丢弃的）
4. P99 延迟不超过无代理时 500ms
```

---

## 4. 部署方案

### 4.1 容器部署

#### 容器规格

| 项目 | 规格 |
|------|------|
| 镜像 | `kyb-infra-api-proxy:latest`（基于 `scratch` 或 `alpine:3.19`） |
| 端口 | `:2082`（HTTP 代理端口）, `:2083`（健康检查端口 / 可与 2082 复用） |
| 资源限制 | `--memory=128m --cpus=0.5` |
| 网络 | `kyb-net`（Docker 内部网络） |
| 重启策略 | `restart: always` |
| 依赖 | ClickHouse（CK 不可用时 degrade，不 crash） |

#### docker-compose 定义

```yaml
services:
  kyb-infra-api-proxy:
    image: kyb-infra-api-proxy:latest
    container_name: kyb-infra-api-proxy
    restart: always
    ports:
      - "2082:2082"   # 代理端口（Docker 内部 + 宿主机 localhost）
      - "2083:2083"   # 健康检查端口
    environment:
      - LISTEN_ADDR=:2082
      - HEALTH_ADDR=:2083
      - UPSTREAM_URL=https://api.deepseek.com/anthropic/v1/messages
      - CK_DSN=clickhouse://clickhouse:9000/infra
      - CK_USER=default
      - CK_PASSWORD=
      - REQUEST_TIMEOUT=10s
      - CIRCUIT_BREAKER_THRESHOLD=3
      - LOG_LEVEL=info
    networks:
      - kyb-net
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: '0.5'
```

#### 资源估算

| 指标 | 估值 | 说明 |
|------|------|------|
| 单请求内存 | ~50KB | 含 request/response buffer |
| 100 并发 | ~5MB | 请求本体 |
| SSE buffer | ~2MB | 单 streaming 响应 buffer 上限 |
| 总内存 | < 50MB | 高峰期 |
| 网络带宽 | 与 DeepSeek 调用频率相关 | 当前每日 ~1000 次调用，约 50MB 流量 |
| CPU | < 0.1 core | 主要开销在 JSON 解析（轻量） |

### 4.2 灰度切流步骤

#### Phase 0：部署代理但不改 Claude 配置（空跑验证）

```
Step 1: 创建 infra.api_logs 表（CK）
Step 2: 构建并部署 kyb-infra-api-proxy 容器
Step 3: 验证代理 /healthz 和 /readiness 正常
Step 4: 用 curl 手动测试代理：
    curl -x http://kyb-infra-api-proxy:2082 https://api.deepseek.com/anthropic/v1/messages -H ...
    验证 CK 有写入
Step 5: 并行部署 sing-box mirror（方案 B）作为流量监控副产物
```

#### Phase 1：切一个非关键容器

```
Step 1: 选一个低风险的 sandbox（如测试用 sandbox，非 boss 容器）
Step 2: 修改该容器的 ANTHROPIC_BASE_URL：
    docker exec <sandbox> sh -c 'echo "export ANTHROPIC_BASE_URL=http://kyb-infra-api-proxy:2082" >> ~/.bashrc'
        或
    修改 docker-compose，重建容器
Step 3: 验证该 sandbox 的 Claude 能正常对话
Step 4: 验证 CK infra.api_logs 有该 sandbox 的请求记录
Step 5: 观察 24 小时，确认无异常
```

#### Phase 2：逐个切 boss 容器（最高风险）

```
Step 1: 备份当前 ANTHROPIC_BASE_URL 值（如有）
Step 2: 修改 kyb-infra-boss 的 ANTHROPIC_BASE_URL
Step 3: 立即验证：
    - Claude 能正常响应
    - CK 有日志写入
    - 延迟没有明显增加
Step 4: 接下来 1 小时内手动监控
    - 每 5 分钟检查一次代理的健康状态
    - 检查 CK 写入延迟
    - 检查错误率
Step 5: 24 小时后进入稳定期
```

#### Phase 3：扩展所有 sandbox

```
Step 1: 修改 kyb create 模板，默认注入 ANTHROPIC_BASE_URL
Step 2: 修改 entrypoint.sh，在新 sandbox 创建时自动设置
Step 3: 对于现有 sandbox，逐个通知更新
Step 4: 所有 sandbox 切换完毕后，观察 1 周
```

### 4.3 回滚方案

#### 快速回滚（单个容器）

```bash
# 直连：直接清除 env 变量
docker exec <sandbox> sh -c 'unset ANTHROPIC_BASE_URL'
# 或修改 bashrc
docker exec <sandbox> sh -c "sed -i '/ANTHROPIC_BASE_URL/d' ~/.bashrc"
```

#### 批量回滚（全部容器）

```bash
# 如果有配置中心
configctl set global/ANTHROPIC_BASE_URL "" && reload-all

# 如果没有，逐个容器执行
for c in $(docker ps --format '{{.Names}}' | grep '^kyb-'); do
  docker exec "$c" sh -c 'unset ANTHROPIC_BASE_URL'
done
```

#### 容器级回滚

如果代理容器本身有问题：

```bash
docker stop kyb-infra-api-proxy
# 所有使用代理的 Claude 容器的请求会失败
# 然后执行快速回滚（清除所有容器的 ANTHROPIC_BASE_URL）
```

#### 应急回滚 Playbook

```
1. 发现代理故障（告警或用户反馈）
2. 立即执行：echo "ANTHROPIC_BASE_URL=" > /tmp/fallback-env
3. Watch 进程检测到 → 清除所有容器的 ANTHROPIC_BASE_URL
4. 验证：glab issue view 169（直接走 DeepSeek）
5. 修复代理容器（查看日志、修复 bug、重新部署）
6. 验证：代理健康检查通过
7. 重新灰度切流
```

### 4.4 监控告警

#### 代理自身指标

代理暴露 Prometheus 格式的 `/metrics` 端点：

| 指标 | 类型 | 标签 | 说明 |
|------|------|------|------|
| `proxy_requests_total` | Counter | `model, status_code, streaming` | 总请求数 |
| `proxy_request_duration_ms` | Histogram | `model, streaming` | 请求延迟分布 |
| `proxy_ttft_ms` | Histogram | `model` | 首 token 延迟（仅 streaming） |
| `proxy_circuit_breaker_state` | Gauge | — | 0=CLOSED, 1=HALF-OPEN, 2=OPEN |
| `proxy_ck_write_duration_ms` | Histogram | `status` | CK 写入延迟 |
| `proxy_ck_write_errors_total` | Counter | — | CK 写入失败数 |
| `proxy_upstream_errors_total` | Counter | `error_type` | DeepSeek 转发失败数 |
| `proxy_memory_usage_bytes` | Gauge | — | 当前内存使用 |
| `proxy_sse_buffer_bytes` | Gauge | — | SSE buffer 当前大小 |
| `proxy_goroutines_active` | Gauge | — | 活跃 goroutine 数 |

#### Grafana 面板

| 面板 | 图表类型 | 指标 |
|------|----------|------|
| 请求量 | Time Series | `rate(proxy_requests_total[1m])` |
| 延迟 P50/P90/P99 | Time Series | `histogram_quantile(0.99, proxy_request_duration_ms)` |
| 错误率 | Time Series | `rate(proxy_requests_total{status_code=~"5.."}[5m]) / rate(proxy_requests_total[5m])` |
| Token 消耗 | Stacked Area | `sum(prompt_tokens)` + `sum(completion_tokens)` from CK |
| 熔断状态 | State Timeline | `proxy_circuit_breaker_state` |
| CK 写入健康 | Time Series | `rate(proxy_ck_write_errors_total[5m])` |
| 各 model 分布 | Pie | `count by model` from CK |

#### 告警规则

| 告警名 | 级别 | 条件 | 响应 |
|--------|------|------|------|
| `ProxyDown` | **P0** | 健康检查失败 > 30s | 自动回滚所有容器的 ANTHROPIC_BASE_URL |
| `ProxyErrorRateHigh` | **P1** | 5xx 错误率 > 5% 持续 5 分钟 | 检查 DeepSeek 状态，检查代理日志 |
| `ProxyCircuitBreakerOpen` | **P0** | 熔断器 OPEN 超过 30 秒 | 自动 fallback，通知管理员 |
| `ProxyLatencyHigh` | **P2** | P99 延迟 > 5s 持续 5 分钟 | 检查 DeepSeek 延迟，检查代理资源 |
| `ProxyCkWriteFailing` | **P2** | CK 写入失败率 > 5% 持续 5 分钟 | 检查 CK 集群状态 |
| `ProxyMemoryHigh` | **P2** | 内存 > 100MB | 检查是否有泄漏 |
| `ProxyNoTraffic` | **P2** | 连续 30 分钟无请求 | 可能代理未连接到任何 Claude 容器（配置问题） |

#### 告警通知渠道

| 级别 | 通知方式 | 响应 SLO |
|------|----------|----------|
| **P0** | 飞书群 + 电话 | 5 分钟内响应 |
| **P1** | 飞书群 | 15 分钟内响应 |
| **P2** | 飞书群（不 @ 人） | 工作时间内响应 |

---

## 附录

### A. 与现有基础设施的关系

```
现有组件         DeepSeek API 代理
──────────────────────────────────────────────────
cc-connect      ← 不受影响（cc-connect 不调 DeepSeek）
Claude hooks    ← 互补（hooks: tool 级别, proxy: API 级别）
CK              ← 共享（proxy 写入 infra.api_logs, hooks 写入 kyb.claude_hook_events）
Sing-box        ← 并行部署方案 B（proxy 做内容记录，sing-box 做流量监控）
Grafana         ← 新增 data source：infra.api_logs
```

### B. 安全考虑

1. **API key 不落盘** — CK 中只存 `api_key_prefix`（前 8 位）
2. **容器间通信加密** — Claude → 代理走 Docker 内部网络（不暴露到宿主机外部），代理 → DeepSeek 走 HTTPS
3. **内容脱敏** — 考虑在代理层添加 PII 脱敏（正则替换 email、phone、api key 等），作为 Phase 1 可选功能
4. **最小端口暴露** — `:2082` 仅在 `kyb-net` 网络暴露，不绑定 `0.0.0.0`（默认绑定 Docker 内部 IP）
5. **日志访问控制** — `infra.api_logs` 表在 CK 中通过用户权限控制，仅 infra 管理员可查询

### C. 决策记录

| 日期 | 决策 | 理由 |
|------|------|------|
| 2026-05-24 | 选方案 E（反向代理）而非 A（MITM） | 规避 TLS MITM 复杂度 |
| 2026-05-25 | 语言选 Go 而非 Ruby/Python | 关键路径确定性延迟、单二进制部署 |
| 2026-05-25 | Streaming 用逐 chunk 透传 + 内存拼接 | 最小化首字节延迟 |
| 2026-05-25 | CK 写入 fail-open | 代理不能因 CK 故障而阻塞请求 |
| 2026-05-25 | 熔断阈值连续 3 次失败 | 保守 — meta-infra 级别宁可误触不可不触 |
| 2026-05-25 | Fallback 方式为修改 ANTHROPIC_BASE_URL | 最彻底的直连恢复，不依赖 Claude 侧逻辑 |

### D. 未解决问题（待 Phase 1 设计）

1. **API key 统一管理** — 当前各容器各自持有 DeepSeek API key，代理无法统一管理。未来是否需要代理集中管理 key？
2. **缓存策略** — 相同 prompt 是否返回缓存结果？对于调试场景不合适，对成本敏感场景有价值。需要更明确的需求。
3. **采样率** — 是否需要支持采样（如只记录 10% 的请求）用于降本？
4. **请求审计与 replay** — 能否从 CK 中提取请求，重新发送到 DeepSeek？功能上可行，但需要额外的 replay 工具。

---

> **本文件由 boss 设计，Claude Code (DeepSeek) 编写，人审通过后进入 Phase 1 测试方案阶段。**
>
> ／人◕ ‿‿ ◕人＼
