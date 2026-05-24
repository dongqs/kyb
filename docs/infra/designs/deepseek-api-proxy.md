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
3. **内置连接池** — `http.Transport` 默认启用 keep-alive 和连接池，对 DeepSeek 的 TLS 连接会自动复用。Ruby 的 `net/http` 默认不启用 persistent——忘记配就是性能灾难。生产环境显式配置 `MaxIdleConns=100`、`MaxIdleConnsPerHost=50` 以应对高并发场景。
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
                     │ POST /v1/messages          │
                     │ POST /v1/models           │
                     │ GET  /v1/models            │
                     │ (Anthropic 兼容路径均路由)   │
                     ▼
┌──────────────────────────────────────────────────────────────────┐
│ kyb-infra-api-proxy (:2082)                                       │
│                                                                   │
│  ┌──────────────┐     ┌──────────────┐     ┌─────────────────┐   │
│  │ Receive      │────▶│ SSRF Check   │────▶│ Forward to      │   │
│  │ Handler      │     │ (URL 白名单)  │     │ DeepSeek        │   │
│  └──────────────┘     └──────────────┘     └───────┬─────────┘   │
│        │                                            │             │
│        │  ┌──────────────┐                          │             │
│        └─▶│ Buffer req   │                          │             │
│           │ in memory    │                          │             │
│           └──────────────┘                          │             │
│                                                     │             │
│           ┌──────────────┐               ┌──────────┴─────────┐  │
│           │ INSERT all   │◀──────────────│ Response complete  │  │
│           │ at once to   │  (async CK)   │ + buffer assembled │  │
│           │ infra.api_logs│              │ (ctx.Background()) │  │
│           └──────────────┘              └────────────────────┘  │
│                                                                   │
│  ┌──────────────┐                                               │
│  │ Health Check │  :2082/healthz                                │
│  │ (every 30s)  │  :2082/readiness                              │
│  └──────────────┘                                               │
└──────────────────────┬─────────────────────────────────────────┘
                       │ HTTPS (原始 TLS)
                       │ api.deepseek.com/anthropic/v1/messages
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│ api.deepseek.com                                                  │
│ Anthropic 兼容接口                                                 │
└─────────────────────────────────────────────────────────────────┘

                         ╔═══════════════════════╗
                         ║   ClickHouse          ║
                         ║  infra.api_logs       ║
                         ║  INSERT all-at-once   ║
                         ║  (不 UPDATE, 不拆分   ║
                         ║   req 和 resp 写入)    ║
                         ╚═══════════════════════╝
```

#### 核心流程（非 Streaming）

1. Claude 发送 HTTP POST `http://kyb-infra-api-proxy:2082/v1/messages`
2. 代理接收完整 request body，提取 `model`、`messages`、`stream` 字段
3. 代理在校验 SSRF 白名单后，转发请求到 `https://api.deepseek.com/anthropic/v1/messages`
   - 保留原始 HTTP headers（`Authorization`, `Content-Type`, `anthropic-version`）
   - 修改 `Host` 为 `api.deepseek.com`
   - 添加 `X-Request-Id` 用于追踪
4. DeepSeek 返回完整 JSON response
5. 代理读取完整 response body，提取 `usage`（prompt_tokens, completion_tokens）
6. 组装完整的日志记录（含 request_body + response_body + usage + latency_ms + status_code）
7. 使用 `context.Background()` 异步 INSERT 一条完整记录到 `infra.api_logs`
   （绝不使用 `r.Context()`，避免请求取消后 CK 写入被取消）
8. 代理将 response 原样返回给 Claude

#### 核心流程（Streaming / SSE）

1. Claude 发送 HTTP POST `http://kyb-infra-api-proxy:2082/v1/messages`（`stream: true`）
2. 代理接收完整 request body
3. 代理在校验 SSRF 白名单后转发请求到 DeepSeek
4. DeepSeek 返回 `Transfer-Encoding: chunked` + `Content-Type: text/event-stream`
5. 代理逐行读取 SSE chunks
   - `event: message_start` → 记录起始时间（TTFT = now - start）
   - `event: content_block_delta` → 拼接 completion text，提取 `delta.reasoning_content`（如存在）
   - `event: message_delta` → 提取 usage（delta.usage）
   - `event: message_stop` → 标记 streaming 完成
   - `event: error` → 标记 error
6. 每收到一个 chunk，立即 `w.Write(chunk)` + `w.(http.Flusher).Flush()` 转发给 Claude（**零延迟透传**）
7. 在内存 buffer 中拼接 completion chunks（含 reasoning_content）
8. `message_stop` 事件后，使用 `context.Background()` 异步 INSERT 一条完整记录到 `infra.api_logs`
   （含 request_body, response_body, usage, latency_ms, ttft_ms, streaming=true）

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
  │◀────────────────────────│  w.Write(chunk)        │
  │                         │  w.(http.Flusher).     │
  │                         │    Flush()             │
  │                         │  (buffer chunk 1 in    │
  │                         │   memory, forward      │
  │                         │   immediately)         │
  │                         │                        │
  │                         │  event: content_block_ │
  │                         │  delta (chunk N)       │
  │                         │◀───────────────────────│
  │  chunk N                │                        │
  │◀────────────────────────│  w.Write(chunk)        │
  │                         │  w.(http.Flusher).     │
  │                         │    Flush()             │
  │                         │  (buffer chunk N)      │
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
  │                         │  (context.Background())│
```

#### 关键设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 写入时机 | `message_stop` 后一次性写入 | Streaming 过程中无需写入 CK（数据不完整），减少 CK 写入次数 |
| 内存 buffer | 最多 2MB 或 5 分钟 | 防止超长 response 撑爆内存。超过限制后截断，标记 `truncated=true` |
| CK 写入延迟 | 增加 0ms（异步，不阻塞转发） | 转发和 CK 写入在两个独立 goroutine |
| 连接中断处理 | 已收到的 chunks 写入 CK，标记 `error=stream_interrupted` | 避免日志完全丢失 |
| Content-Type 检测 | 非 SSE 响应按非 streaming 流程处理 | 兼容 DeepSeek 可能返回的非 streaming fallback |
| **每 chunk Flush** | 每 chunk 后调用 `Flush()` | HTTP ResponseWriter 默认缓冲，不 Flush 则 chunk 积攒到 TCP 窗口满才发送，零延迟透传失效 |
| **Scanner buffer** | 设为 1MB（`bufio.Scanner.Buffer(buf, 1024*1024)`） | 默认 `bufio.Scanner` 最大 token 64KB，超过时 `ErrTooLong` 导致截断。长 payload（如超大 content_block_delta）需要更大 buffer |

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
    │   │   - delta.reasoning_content 追加到 reasoning buffer（DeepSeek reasoner 模型专用）
    │   │   - 立即转发给 Claude（含 reasoning_content 字段）
    │   │   - w.(http.Flusher).Flush() 确保立即发送
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

> **关于写入模式**：CK MergeTree 引擎**不支持 UPDATE/DELETE**（仅支持 `ALTER TABLE ... DELETE` 或 `ALTER TABLE ... UPDATE` 这种重量级 mutation，性能极差且不应用作常规写入路径）。
>
> 因此本设计采用 **all-at-once INSERT** 模式：代理始终先收齐完整请求 + 完整响应（或 streaming 结束后的完整拼接），组装好所有字段，再一次性 INSERT 一整行。不存在"先写请求再 UPDATE 响应"的两阶段写入。
>
> 对于 streaming 场景，代理在 `message_stop` 事件后组装所有数据，一次性 INSERT。

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
| DeepSeek 连接超时（connect_timeout=10s） | 返回 504，Claude 侧自行重试 | status_code=504, error="connect_timeout" |
| DeepSeek DNS 解析失败 | 返回 502 | status_code=502, error="dns_resolution_failed" |
| DeepSeek TLS 握手失败 | 返回 502 | status_code=502, error="tls_handshake_failed" |
| DeepSeek 空闲超时（idle_timeout=60s，无任何数据到达） | 返回 504，Claude 侧自行重试 | status_code=504, error="idle_timeout" |
| DeepSeek 总超时（total_timeout=300s，非 streaming 用 30s） | 返回 504 | status_code=504, error="total_timeout" |
| DeepSeek 返回 4xx（含 429） | 原样返回 Claude（需经错误格式转换，见下文） | status_code=实际值, error="" |
| DeepSeek 返回 5xx | 原样返回 Claude（不自动重试，避免重复日志，需经错误格式转换） | status_code=实际值, error="" |
| DeepSeek 返回非法 body | 返回 502 | status_code=502, error="invalid_response_body" |
| SSE 解析错误 | 返回 502 | status_code=502, error="sse_parse_error" |

**关键原则：不要代替 Claude 做重试。** 重试决策在 Claude 侧（或上层业务逻辑），代理只做透传。代理侧的重试会导致重复日志，且与 Claude 侧的重试冲突。

#### 错误格式转换

Claude Code 和 Anthropic SDK 期望的 API 错误响应格式与 DeepSeek 的原生格式不同。代理必须将 DeepSeek 错误响应统一转为 Anthropic 兼容格式：

**DeepSeek 原生错误格式：**
```json
{
  "error": {
    "message": "Rate limit exceeded",
    "type": "rate_limit_error"
  }
}
```

**Anthropic 兼容错误格式（代理转换后）：**
```json
{
  "type": "error",
  "error": {
    "type": "rate_limit_error",
    "message": "Rate limit exceeded"
  }
}
```

**转换规则：**

| DeepSeek error.type | Anthropic error.type | HTTP 状态码 |
|---------------------|---------------------|-------------|
| `rate_limit_error` | `rate_limit_error` | 429 |
| `invalid_request_error` | `invalid_request_error` | 400 |
| `authentication_error` | `authentication_error` | 401 |
| `permission_error` | `permission_error` | 403 |
| `server_error` / `internal_error` | `api_error` | 500/502/503 |
| `insufficient_quota` | `rate_limit_error` | 429 |
| 其他 / 未知 | `api_error` | 502 |

**实现要点：**
- 代理对 DeepSeek 返回的所有错误响应（状态码 >= 400）进行格式转换
- 转换发生在转发给 Claude 之前
- 同时转发 HTTP 状态码 + 经过格式转换的 JSON body
- 对于代理自身产生的错误（504/timeout/DNS 等），也使用相同的 Anthropic 格式返回
- 格式转换代码必须在错误路径最前端执行，确保不会遗漏任何错误响应

#### CK 写入层错误

| 错误类型 | 行为 |
|----------|------|
| CK 连接失败 | 跳过写入，不阻塞响应。尝试写入本地 buffer（最多保留 1000 条或 64MB，任一达到即截断），后续成功时补写 |
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

熔断阈值使用 **滑动窗口 + 失败率** 而非计数绝对值，避免因瞬时流量波动导致的误触。

```
┌──────────────────────────────────────────────────────────────────┐
│ 熔断配置 — 滑动窗口模式                                            │
├──────────────────────────────────────────────────────────────────┤
│  window_size:           5m       # 滑动窗口大小（滚动 5 分钟）     │
│  failure_rate_threshold: 20%     # 窗口内失败率 > 20% → OPEN     │
│  min_request_count:     10      # 窗口内最少请求数（避免样本不足   │
│                                 #  时因 1 次失败就熔断）          │
│  half_open_timeout:     30s     # OPEN → HALF-OPEN 等待时间      │
│  half_open_max_retry:   3       # HALF-OPEN 最大连续试探失败次数  │
│  health_check_interval: 10s     # 内部巡检间隔                    │
├──────────────────────────────────────────────────────────────────┤
│ 失败判定条件（满足任一计入失败计数）                                 │
├──────────────────────────────────────────────────────────────────┤
│  1. 转发 DeepSeek 超时（connect_timeout > 10s）                    │
│  2. DeepSeek 返回 502/503                                        │
│  3. SSE 解析错误                                                  │
│  4. 代理内部错误（panic、buffer 溢出等）                            │
│                                                                  │
│ 注意：429/4xx 不计入失败计数（这是 DeepSeek 限流，不是代理故障）     │
│      CK 写入失败单独计数，不影响熔断决策（CK 是副通道）              │
└──────────────────────────────────────────────────────────────────┘
```

#### 熔断状态切换

```
CLOSED → OPEN:  滑动窗口 5m 内失败率 > 20% 且总请求数 >= 10
OPEN → HALF-OPEN: 30 秒后自动进入
HALF-OPEN → CLOSED: 放行一个探测请求成功 → 再放行一个验证请求成功
HALF-OPEN → OPEN: 探测请求失败 → 重新等待 30s
```

**滑动窗口实现要点：**

采用 **环形数组（ring buffer）** 实现滑动窗口，每个桶记录 10s 内的请求总数和失败数：

```
时间轴:  |--10s--|--10s--|--10s--|...|--10s--|  (30 个桶 = 5m)
          ^                                       ^
          now-5m                                  now

每 10s 滚动一个桶：
  1. 清空过期桶
  2. 新建当前桶
  3. 求和所有非过期桶的 failed / total
  4. failed / total > 20% && total >= 10 → OPEN
```

O(1) 时间复杂度，无锁原子操作更新计数器，不阻塞请求路径。

#### 熔断触发后的行为

当熔断器进入 **OPEN** 状态时：

1. **代理层 fallback**：代理不再转发到 DeepSeek，而是返回一个特殊的 HTTP 响应给 Claude，指示 Claude 直接连接到 DeepSeek（通过响应 header）
2. **但代理仍响应对健康检查的请求**：`/healthz` 和 `/readiness` 始终可用
3. **熔断状态通过 `/readiness` 暴露**：返回 503 + `{"status": "open", "circuit_breaker": true}`

### 2.4 Fallback 到直连 DeepSeek

#### 方案 A：ANTHROPIC_BASE_URL 切换（推荐）

这是最彻底的 fallback：当代理熔断时，修改 Claude 容器的 `ANTHROPIC_BASE_URL` 跳过多层：

```
正常:   ANTHROPIC_BASE_URL=http://kyb-infra-api-proxy:2082
熔断:   ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic (直连)
恢复:   ANTHROPIC_BASE_URL=http://kyb-infra-api-proxy:2082 (重新切回)
```

**切换方式（按优先级）：**

| 优先级 | 方式 | 延迟 | 适用场景 |
|--------|------|------|----------|
| P0 | **自动恢复（Watch 进程）** — 独立 watch 进程检测代理健康状态，自动切换 env | ~1-3s | 自动熔断 + 自动恢复 |
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

#### Watch 进程架构（自动恢复核心）

熔断的自动检测和恢复由一个 **独立 watch 进程** 负责，该进程与代理进程分离部署，确保代理自身故障时 watch 仍能工作。

```
┌──────────────────────────────────────────────────────────────────┐
│ Watch 进程 (kyb-infra-api-proxy-watch)                            │
│                                                                   │
│ 部署位置: 宿主机 systemd 服务 (非 Docker 内部)                     │
│ 或:       kyb-infra-boss 容器内的 sidecar 进程                    │
│ 语言:     Go（与代理复用代码）或 Shell（简单 curl + sed）           │
│ 资源:     极低 (<10MB, <0.01 core)                               │
│                                                                   │
│ 核心循环 (每 3s 执行一次):                                         │
│ ┌────────────────────────────────────────────────────────────┐    │
│ │ 1. GET http://kyb-infra-api-proxy:2082/healthz            │    │
│ │    ├── 200 → proxy_healthy = true                         │    │
│ │    └── 失败 → proxy_healthy = false, 失败计数++            │    │
│ │                                                           │    │
│ │ 2. 读取当前 ANTHROPIC_BASE_URL 状态 (从共享文件)           │    │
│ │    ├── current_mode = "proxy" 或 "direct"                 │    │
│ │                                                           │    │
│ │ 3. 策略判断:                                              │    │
│ │    ├── 当前=proxy 且 proxy_healthy=false 持续>10s         │    │
│ │    │   → 执行 fallback: 设置 ANTHROPIC_BASE_URL=直连      │    │
│ │    │   → 写入共享状态: mode=direct                        │    │
│ │    │                                                      │    │
│ │    ├── 当前=direct 且 proxy_healthy=true 持续>30s         │    │
│ │    │   → 执行恢复: 设置 ANTHROPIC_BASE_URL=代理           │    │
│ │    │   → 写入共享状态: mode=proxy                         │    │
│ │    │                                                      │    │
│ │    └── 其他 → 不操作                                      │    │
│ └────────────────────────────────────────────────────────────┘    │
│                                                                   │
│ 状态共享方式:                                                     │
│  - /tmp/kyb-infra-proxy-state.json (共享文件, 宿主机文件系统)     │
│  - 内容: {"mode":"proxy|direct","healthy":true|false,            │
│           "last_changed":"2026-05-25T12:00:00Z"}                 │
└──────────────────────────────────────────────────────────────────┘
```

**ANTHROPIC_BASE_URL 切换方式：**

Watch 进程通过 Docker API 或 docker exec 修改目标容器的环境变量：

```bash
# Fallback: 直连 DeepSeek
docker exec <container> sh -c 'echo "export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic" >> ~/.bashrc'
# 对于运行中的进程，发送 SIGHUP 或重新加载配置

# 恢复: 切回代理
docker exec <container> sh -c "sed -i '/ANTHROPIC_BASE_URL/d' ~/.bashrc && \
  echo 'export ANTHROPIC_BASE_URL=http://kyb-infra-api-proxy:2082' >> ~/.bashrc"
```

#### Fallback 时机决策流程

```
收到请求
    │
    ▼
熔断器状态？
    ├── CLOSED → 正常转发到 DeepSeek
    │
    ├── OPEN → 代理返回 502 + Anthropic 格式错误
    │         Watch 进程在下一轮巡检(3s)检测到代理不健康
    │         → 执行 docker exec 修改 ANTHROPIC_BASE_URL
    │         → 后续请求直连 DeepSeek
    │
    └── HALF-OPEN → 放行一个探测请求
        ├── 成功 → CLOSED（恢复正常，watch 在下一轮检测后自动切回）
        └── 失败 → OPEN（继续熔断，watch 不操作）
```

#### 熔断自动恢复流程

```
Watch 进程巡检 (每 3s)
    │
    ▼
代理健康检查通过?
    ├── 否 → 不操作 (已在直连模式)
    │
    └── 是且持续 >30s 健康 → 执行自动恢复:
        1. Watch 读取共享状态 → mode=direct
        2. Watch 执行 docker exec 恢复 ANTHROPIC_BASE_URL 指向代理
        3. Watch 更新共享状态 → mode=proxy, healthy=true
        4. 后续请求重新走代理
```

### 2.5 Per-API-Key 速率限制

代理提供基于 API key 维度的速率限制，防止单个用户的突发流量影响其他用户或打满 upstream 配额。

#### 限流策略

基于 **Token Bucket 算法**，每个 API key 拥有独立的令牌桶：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `RATE_LIMIT_REQUESTS_PER_MIN` | 60 | 每 API key 每分钟允许的最大请求数 |
| 桶容量 | `RATE_LIMIT_REQUESTS_PER_MIN` | 令牌桶容量，允许短时突发到该值 |
| 填充速率 | `RATE_LIMIT_REQUESTS_PER_MIN / 60` req/s | 每秒恢复的令牌数 |

#### Key 提取方式

从请求的 `Authorization` header 中提取 API key 的前 8 位作为限流 key：

```
Authorization: Bearer sk-abc123def456ghi7
                           ↓
限流 key: "sk-abc12"（前 8 位，含 "sk-" 前缀）
```

- 提取逻辑与 CK 日志 `api_key_prefix` 字段完全一致
- 无 `Authorization` header 的请求使用 `"anonymous"` 作为限流 key
- 限流 key 仅存内存，不落盘、不记录日志

#### 超出后的响应行为

当 API key 超出速率限制时，代理返回 Anthropic 兼容格式的 429 响应：

```json
{
  "type": "error",
  "error": {
    "type": "rate_limit_error",
    "message": "Rate limit exceeded: 60 requests per minute per API key"
  }
}
```

- HTTP 状态码: **429**
- 响应 Header: `Retry-After: 1`（建议退避 1 秒）
- 错误按正常 429 路径记录到 CK（`infra.api_logs`，`status_code=429`）
- **不计入熔断器失败计数**（429 是客户端限流，非代理/Upstream 故障）
- Claude Code 收到 429 后自动退避重试，无需代理侧特殊处理

#### 实施细节

- 限流状态存储在代理内存中，重启后重置（不持久化）
- 每个 API key 的令牌桶独立，互不影响
- 使用 `sync.Map` 存储 key → token bucket 映射，读多写少场景下性能最优
- 后台 goroutine 每分钟清理超过 5 分钟无活动的 key 条目，防止内存泄漏

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
| TC-20 | 熔断后恢复（滑动窗口） | 5m 内发送 50 个请求，12 个失败（>20%）→ 等待 30s → 发送成功请求 | 熔断 OPEN，30s 后 HALF-OPEN，成功后 CLOSED |
| TC-21 | 错误格式转换 | DeepSeek 返回 429（原生格式） | 代理返回 Anthropic 格式 `{"type":"error","error":{"type":"rate_limit_error","message":"..."}}` |
| TC-22 | PII 脱敏 | request body 含 `"api_key": "sk-xxx"` | CK 中存 `[REDACTED]`，转发内容不做脱敏 |
| TC-23 | 优雅关闭 | 发送 SIGTERM，同时有进行中 streaming 请求 | 进行中请求完成，新请求返回 503，CK buffer flush |
| TC-24 | SSRF 白名单 | 配置 `UPSTREAM_URL=https://evil.com` | 代理启动失败，拒绝非法上游 URL |
| TC-25 | Flush 零延迟验证 | Mock: 100 chunks, 各间隔 10ms | 每 chunk 到达后 1ms 内转发给客户端（响应式 `Flush()` 时间戳差值） |
| TC-26 | 超大 delta chunk（> 64KB） | Mock: 单个 content_block_delta 含 500KB text | bufio.Scanner 正常读取，不截断 |
| TC-27 | API 路径映射 | GET `http://proxy:2082/v1/models` | 正确转发到 `api.deepseek.com/anthropic/v1/models` |
| TC-28 | Watch 进程自动恢复 | 代理不可用（docker stop）→ Watch 检测到 → 切直连 → 代理恢复 → Watch 自动切回 | 整个流程自动完成，无需人工介入 |

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
| 资源限制 | `--memory=256m --cpus=0.5` |
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
      # 仅绑定 127.0.0.1（不暴露到外部网络），Docker 内部通过 kyb-net 访问
      - "127.0.0.1:2082:2082"   # 代理端口
      - "127.0.0.1:2083:2083"   # 健康检查端口
    environment:
      - LISTEN_ADDR=:2082
      - HEALTH_ADDR=:2083
      - UPSTREAM_URL=https://api.deepseek.com/anthropic/v1/messages
      - UPSTREAM_URL_WHITELIST=api.deepseek.com  # SSRF 保护：只允许此域名
      - CK_DSN=clickhouse://clickhouse:9000/infra
      - CK_USER=default
      - CK_PASSWORD=
      # 超时模型（拆分，不共用总超时）
      - CONNECT_TIMEOUT=10s       # TCP 连接超时
      - IDLE_TIMEOUT=60s         # streaming 空闲超时（无数据到达）
      - TOTAL_TIMEOUT=300s       # streaming 总超时（非 streaming 用 30s）
      # 熔断配置
      - CB_WINDOW_SIZE=5m        # 滑动窗口大小
      - CB_FAILURE_RATE=20       # 失败率阈值（百分比）
      - CB_MIN_REQUEST_COUNT=10  # 最少请求数
      - CB_HALF_OPEN_TIMEOUT=30s # 半开等待时间
      # PII 脱敏
      - PII_MASK_ENABLED=true
      - PII_KEYWORDS=token,password,secret,key,credential,authorization
      # 连接池
      - MAX_IDLE_CONNS=100          # 全局最大空闲连接数
      - MAX_IDLE_CONNS_PER_HOST=50  # 每主机最大空闲连接数
      # 速率限制
      - RATE_LIMIT_REQUESTS_PER_MIN=60  # 每 API key 每分钟最大请求数
      # 其他
      - MAX_RETRY_BUFFER_BYTES=64MB # CK 重试 buffer 上限（双重限制：64MB / 1000 条）
      - LOG_LEVEL=info
      - MAX_BUFFER_SIZE=2MB      # SSE buffer 上限
      - SCANNER_BUFFER_SIZE=1MB  # bufio.Scanner 最大行长度
    networks:
      - kyb-net
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '0.5'
```

#### 资源估算

| 指标 | 估值 | 说明 |
|------|------|------|
| 单请求内存 | ~50KB | 含 request/response buffer |
| 100 并发 | ~5MB | 请求本体 |
| SSE buffer | ~2MB per request, budget 64MB total | 单 streaming 响应 buffer 上限，所有并发请求共享 |
| CK retry buffer | ~64MB max | CK 写入失败缓冲，双重限制（64MB / 1000 条） |
| 总内存 | < 128MB | 高峰期（SSE buffer + CK retry buffer < 128MB，容器 limit 256MB 含 headroom） |
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

回滚的核心原则：**切断代理路径，让所有 Claude 容器直连 DeepSeek。**

回滚分三个等级，按严重程度选择。

#### Level 1：Watch 进程自动回滚（最快，<5s）

当熔断器 OPEN 且 watch 进程检测到代理不可用时，自动执行：

```bash
# Watch 进程自动执行（无需人工干预）:
# 1. 读取当前配置的所有 Claude 容器列表
containers=$(docker ps --format '{{.Names}}' | grep -E '^(kyb-|claude-)')

# 2. 逐个切到直连
for c in $containers; do
  docker exec "$c" sh -c '
    sed -i "/ANTHROPIC_BASE_URL/d" ~/.bashrc
    echo "export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic" >> ~/.bashrc
  ' 2>/dev/null || true
done

# 3. 更新共享状态文件
echo '{"mode":"direct","healthy":false,"last_changed":"'"$(date -Iseconds)"'"}' \
  > /tmp/kyb-infra-proxy-state.json
```

**触发条件**：proxy 健康检查连续 4 次失败（约 12s 无响应）+ 熔断器已 OPEN。

#### Level 2：管理员半自动回滚（<30s）

当 watch 进程未自动触发时，管理员手动执行：

```bash
# Step 1: 确认故障
curl -f http://kyb-infra-api-proxy:2082/healthz || echo "PROXY DOWN"

# Step 2: 停止代理容器（可选，防止故障扩散）
docker stop --time=30 kyb-infra-api-proxy

# Step 3: 批量切换所有 Claude 容器到直连
# 方案 A: 通过 watch 进程触发（推荐）
touch /tmp/force-fallback  # watch 进程检测到此文件后执行 fallback

# 方案 B: 直接执行（watch 进程不可用时）
for c in $(docker ps --format '{{.Names}}' | grep -E '^(kyb-|claude-)'); do
  docker exec "$c" sh -c "
    sed -i '/ANTHROPIC_BASE_URL/d' ~/.bashrc
    echo 'export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic' >> ~/.bashrc
  " 2>/dev/null || true
done

# Step 4: 验证回滚生效
docker exec kyb-infra-boss sh -c 'echo $ANTHROPIC_BASE_URL'
# 输出应为: https://api.deepseek.com/anthropic

# Step 5: 通知团队回滚完成
kyb notify urgent "DeepSeek proxy rolled back to direct connect"
```

#### Level 3：容器重建回滚（最彻底，~60s）

当代理配置严重损坏（如 CK schema 变更导致代理 crash-loop）时：

```bash
# Step 1: 停止代理
docker rm -f kyb-infra-api-proxy

# Step 2: 移除所有容器的代理配置 + 重建（如有 docker-compose）
for c in $(docker ps --format '{{.Names}}' | grep -E '^(kyb-|claude-)'); do
  if docker inspect "$c" --format '{{.Config.Env}}' | grep -q ANTHROPIC_BASE_URL; then
    docker stop "$c" && docker start "$c"  # 清除运行时 env（需镜像默认无此变量）
  fi
done

# Step 3: 验证直连正常
curl -s -o /dev/null -w "%{http_code}" \
  https://api.deepseek.com/anthropic/v1/models \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY"

# Step 4: 确认所有关键容器（kyb-infra-boss 等）正常运行
docker ps --filter "status=running" --format "{{.Names}}" | grep kyb-
```

#### 恢复（重新启用代理）

```bash
# 在代理问题修复 + 健康检查通过后:
# Step 1: 确认代理健康
curl -f http://kyb-infra-api-proxy:2082/healthz

# Step 2: 触发 watch 进程自动恢复（或手动执行）
rm -f /tmp/force-fallback
# Watch 进程检测到代理健康持续 >30s → 自动切回

# Step 3: 手动验证
docker exec kyb-infra-boss sh -c 'echo $ANTHROPIC_BASE_URL'
# 输出应为: http://kyb-infra-api-proxy:2082
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

### 4.5 优雅关闭（Graceful Shutdown）

代理必须实现 SIGTERM/SIGINT 处理，确保关闭过程中不丢弃进行中的请求。

```
收到 SIGTERM
    │
    ▼
1. 标记拒绝新请求
   - HTTP 服务器停止接受新连接（Shutdown 或健康检查返回 503）
   - 进行中的请求继续处理
    │
    ▼
2. 等待进行中请求完成
   - 非 streaming: 等待 HTTP handler 返回
   - streaming: 标记"关闭中"，当前 chunks 继续转发，
     但不再接受新的 streaming 请求
    │
    ▼
3. Flush CK buffer
   - 等待 CK 异步写入 goroutine 处理完 buffer 中的剩余记录
   - 超时 5s 后强制退出（不阻塞进程关闭）
    │
    ▼
4. 关闭连接池
   - 关闭到 DeepSeek 的 HTTP 连接池
   - 关闭到 CK 的连接
    │
    ▼
5. 进程退出 (exit 0)
```

**Go 实现要点：**

```go
// 伪代码 — 描述设计，非实现
func main() {
    ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
    defer stop()

    srv := &http.Server{Addr: ":2082", Handler: router}

    // 启动 goroutine 监听信号
    go func() {
        <-ctx.Done()
        log.Println("shutting down gracefully...")

        // 1. 拒绝新请求（健康检查返回 503）
        atomic.StoreInt32(&shuttingDown, 1)

        // 2. 等待进行中请求完成（最多 30s）
        shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
        defer cancel()
        srv.Shutdown(shutdownCtx)

        // 3. 等待 CK buffer flush（最多 5s）
        ckBuffer.FlushWithTimeout(5 * time.Second)

        log.Println("shutdown complete")
    }()

    srv.ListenAndServe()
}
```

**关键设计点：**

| 问题 | 方案 | 理由 |
|------|------|------|
| 关闭中收到新请求 | 返回 503 + `{"type":"error","error":{"type":"overloaded_error","message":"proxy shutting down"}}` | Claude 侧自动重试到其他端点（或直连） |
| Streaming 进行中 | 不中断，等待 `message_stop` 或 idle_timeout 超时 | 避免 completion 丢失一半 |
| CK 异步写入未完成 | 等待最多 5s，超时后丢弃剩余 | 不阻塞关闭进程 |
| 健康检查在关闭期间 | 返回 503 | 负载均衡器 / watch 进程检测到后切走流量 |

---

## 5. 性能基准与验收标准

### 5.1 代理引入的额外延迟

代理在请求路径上增加的延迟必须可量化、可验收。以下是代理引入的额外延迟（不包含 DeepSeek 自身延迟）：

| 场景 | 目标 P50 | 目标 P99 | 测量方法 |
|------|----------|----------|----------|
| **非 streaming**（透传） | < 5ms | < 20ms | 代理记录 `latency_ms` − DeepSeek 响应时间 |
| **Streaming TTFT**（首字节） | < 5ms | < 20ms | 代理从收到请求到发出第一个 chunk 的时间 |
| **Streaming 每 chunk** | < 1ms | < 5ms | 从收到 DeepSeek chunk 到 `Flush()` 返回的时间 |
| **CK 异步写入** | 不影响响应 | 不影响响应 | 异步 goroutine，零阻塞转发路径 |
| **健康检查响应** | < 1ms | < 5ms | watch 进程测量 |

### 5.2 端到端延迟验收标准

与直接调用 DeepSeek（无代理）对比，端到端延迟增幅：

| 指标 | 无代理 | 经代理 | 允许增幅 |
|------|--------|--------|----------|
| P50 延迟 | DeepSeek 基线 | 基线 + <50ms | < 50ms |
| P99 延迟 | DeepSeek 基线 | 基线 + <200ms | < 200ms |
| Streaming TTFT | DeepSeek 基线 | 基线 + <50ms | < 50ms |
| 错误率 | DeepSeek 基线 | 基线 ± 0.5% | 不增加错误 |

### 5.3 吞吐量验收标准

| 指标 | 目标 | 测试条件 |
|------|------|----------|
| 最大并发请求 | >= 200 | 200 个 goroutine 同时转发到 Mock DeepSeek |
| 最大吞吐 | >= 1000 req/s | 非 streaming，每个响应 ~1KB |
| 最大 streaming 连接数 | >= 50 | 50 个 concurrent SSE 流，各持续 30s |
| 内存上限 | < 256MB | 上述所有并发条件下 |

### 5.4 验收测试工具

```bash
# 使用 hey 或 wrk 进行吞吐量测试
# 注意: 测试目标是 Mock DeepSeek server，非生产环境

# 非 streaming 吞吐
hey -n 10000 -c 100 -m POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"model":"deepseek-chat","messages":[{"role":"user","content":"hello"}],"stream":false}' \
  http://localhost:2082/v1/messages

# Streaming 吞吐
hey -n 1000 -c 50 -m POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-key" \
  -d '{"model":"deepseek-chat","messages":[{"role":"user","content":"hello"}],"stream":true}' \
  http://localhost:2082/v1/messages

# 延迟对比（直接 vs 代理）
time curl -s -o /dev/null -w "direct: %{time_total}s\n" \
  https://api.deepseek.com/anthropic/v1/messages -H "Authorization: Bearer $KEY" -d '...'

time curl -s -o /dev/null -w "via proxy: %{time_total}s\n" \
  http://localhost:2082/v1/messages -H "Authorization: Bearer $KEY" -d '...'
```

### 5.5 性能劣化触发告警

当以下任一条件触发时，产生 P2 告警：

- 代理 P50 引入延迟 > 50ms（持续 5 分钟）
- 代理 P99 引入延迟 > 200ms（持续 5 分钟）
- 代理内存 > 192MB（容器 limit 256MB 的 75%）
- 代理 goroutine 数 > 5000（可能泄漏）

---

## 6. CI/CD 与部署流水线

### 6.1 镜像构建与版本管理

| 项目 | 方案 |
|------|------|
| 基础镜像 | `golang:1.22-alpine` 构建 → `distroless/static:nonroot` 运行 |
| 构建方式 | Docker multi-stage build |
| 版本策略 | SemVer + git commit SHA：`kyb-infra-api-proxy:1.2.3` 和 `kyb-infra-api-proxy:1.2.3-abc1234` |
| 镜像仓库 | Docker Hub 或自建 registry（`registry.kyb.internal/kyb-infra-api-proxy`） |
| CI 平台 | 复用 kyb 项目的 GitLab CI（`.gitlab-ci.yml`） |
| 产物 | Docker 镜像 + 编译后的静态二进制（便于直接部署到宿主机） |

### 6.2 GitLab CI 流水线定义

```yaml
# .gitlab-ci.yml (在 kyb 仓库中作为额外 job，或独立仓库)
stages:
  - test
  - build
  - deploy

variables:
  IMAGE_NAME: registry.kyb.internal/kyb-infra-api-proxy
  IMAGE_TAG: ${CI_COMMIT_TAG:-$CI_COMMIT_SHORT_SHA}

# Stage 1: 测试
test:
  stage: test
  image: golang:1.22-alpine
  script:
    - go test ./... -v -race -coverprofile=coverage.out
    - go vet ./...
  artifacts:
    paths:
      - coverage.out

# Stage 2: 构建 Docker 镜像
build:
  stage: build
  image: docker:24
  services:
    - docker:dind
  script:
    - docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .
    - docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${IMAGE_NAME}:latest
    - docker push ${IMAGE_NAME}:${IMAGE_TAG}
    - docker push ${IMAGE_NAME}:latest
  only:
    - tags
    - master

# Stage 3: 部署（手动触发）
deploy-staging:
  stage: deploy
  script:
    - ssh kyb-infra-host "docker pull ${IMAGE_NAME}:${IMAGE_TAG}"
    - ssh kyb-infra-host "docker-compose -f /opt/kyb-infra/docker-compose.yml up -d kyb-infra-api-proxy"
  environment:
    name: staging
  when: manual
  only:
    - master

deploy-production:
  stage: deploy
  script:
    # 灰度 1: 先更新非关键容器
    - ssh kyb-infra-host "docker service update --image ${IMAGE_NAME}:${IMAGE_TAG} kyb-infra-api-proxy"
    # 灰度 2: 观察 10 分钟
    - sleep 600
    # 灰度 3: 确认健康后标记完成
    - curl -f http://kyb-infra-api-proxy:2082/healthz && echo "Deploy OK"
  environment:
    name: production
  when: manual
  only:
    - tags
```

### 6.3 Dockerfile 设计

```dockerfile
# Stage 1: 构建
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /app/proxy ./cmd/proxy

# Stage 2: 运行（最小镜像）
FROM gcr.io/distroless/static:nonroot
COPY --from=builder /app/proxy /proxy
EXPOSE 2082 2083
ENTRYPOINT ["/proxy"]
```

### 6.4 部署拓扑

```
┌──────────────────────────────────────────────────────────────────┐
│ 宿主机 (kyb-infra-host)                                           │
│                                                                   │
│  ┌──────────────────────┐    ┌──────────────────────────────┐    │
│  │ Docker Compose /     │    │ systemd (宿主机)              │    │
│  │ Docker Stack         │    │                              │    │
│  │                      │    │  kyb-infra-api-proxy-watch    │    │
│  │  kyb-infra-api-proxy │    │  (独立进程, 非 Docker)        │    │
│  │  (容器, kyb-net)     │    │                              │    │
│  │  :2082 → :2082       │    │  用途: 健康巡检 + 自动恢复    │    │
│  │  :2083 → :2083       │    │  粒度: 3s 间隔               │    │
│  └──────────────────────┘    └──────────────────────────────┘    │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ 共享状态文件 /tmp/kyb-infra-proxy-state.json              │    │
│  │ watch 进程写入, 其他工具读取                               │    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

### 6.5 发布流程

```
1. 开发: git commit + push → GitLab CI test + build
2. 测试: 手动部署到 staging 环境（Mock DeepSeek）→ 跑 chaos monkey
3. 打 tag: git tag v1.2.3 → push → GitLab CI 构建生产镜像
4. 灰度: 手动触发 deploy-production job
   - CI pull 新镜像 → docker stack deploy
   - 观察 10 分钟健康状态
   - 验证 perf benchmark 达标
5. 全量: 确认健康后，标记 deploy 完成
6. 回滚: 如有问题，使用上一个 tag 的镜像重新 deploy
```

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
2. **容器间通信加密** — Claude → 代理走 Docker 内部网络（绑定 `127.0.0.1`，不暴露到宿主机外部），代理 → DeepSeek 走 HTTPS
3. **PII 脱敏（P0）** — 代理层必须对 CK 日志中的 PII 做脱敏处理，不可延迟到 Phase 1：
   - **配置化关键词过滤**：通过 `PII_KEYWORDS` 环境变量配置敏感关键词列表（默认：`token,password,secret,key,credential,authorization`）
   - **脱敏规则**：对 `request_body` 和 `response_body` 中匹配关键词的字段值，替换为 `[REDACTED]`
   - **实现方式**：在写入 CK 之前，对 JSON body 做深度遍历，匹配 key 名包含关键词的字段，替换其 value
   - **性能要求**：脱敏处理在写入 goroutine 中异步执行，不增加响应延迟
   - **配置示例**：`PII_KEYWORDS=token,password,secret,key,credential,authorization,api_key,access_key`
   - **注意**：脱敏仅作用于 CK 写入的内容，转发给 Claude 的响应**不**做脱敏（Claude 正常使用需要这些值）
4. **SSRF 保护** — `UPSTREAM_URL` 配置必须经过白名单校验，仅允许 `api.deepseek.com`。`UPSTREAM_URL_WHITELIST` 环境变量控制白名单域名列表，启动时校验，非法域名立即拒绝启动
5. **最小端口暴露** — `:2082` 和 `:2083` 均在 docker-compose 中绑定 `127.0.0.1`，Docker 内部通过 `kyb-net` 网络访问
6. **日志访问控制** — `infra.api_logs` 表在 CK 中通过用户权限控制，仅 infra 管理员可查询

### C. 决策记录

| 日期 | 决策 | 理由 |
|------|------|------|
| 2026-05-24 | 选方案 E（反向代理）而非 A（MITM） | 规避 TLS MITM 复杂度 |
| 2026-05-25 | 语言选 Go 而非 Ruby/Python | 关键路径确定性延迟、单二进制部署 |
| 2026-05-25 | Streaming 用逐 chunk 透传 + 内存拼接 | 最小化首字节延迟 |
| 2026-05-25 | CK 写入 fail-open | 代理不能因 CK 故障而阻塞请求 |
| 2026-05-25 | ~~熔断阈值连续 3 次失败~~ → 滑动窗口 5m 内失败率 >20% | 避免瞬时流量波动误触，需 min_request_count 确保样本足够 |
| 2026-05-25 | Fallback 方式为修改 ANTHROPIC_BASE_URL | 最彻底的直连恢复，不依赖 Claude 侧逻辑 |
| 2026-05-25 | CK MergeTree 采用 all-at-once INSERT（不 UPDATE） | CK 不支持常规 UPDATE，拆分写入不可行 |
| 2026-05-25 | 异步 CK 写入使用 context.Background() | 避免请求取消导致日志写入被取消 |
| 2026-05-25 | 超时模型拆分为 connect / idle / total | 10s 总超时会误杀 streaming（长对话 >10s 正常） |
| 2026-05-25 | Streaming 每 chunk 后 Flush() | HTTP ResponseWriter 默认缓冲，不 Flush 则零延迟透传失效 |
| 2026-05-25 | bufio.Scanner buffer 设为 1MB | 默认 64KB 限制会导致超大 delta chunk 截断 |
| 2026-05-25 | 错误格式从 DeepSeek 原生转为 Anthropic 格式 | Claude SDK 识别特定 error format，格式不匹配导致 SDK 解析异常 |
| 2026-05-25 | PII 脱敏升为 P0（配置化关键词过滤） | 安全审计要求，不可延迟到 Phase 1 |
| 2026-05-25 | 端口绑定 127.0.0.1 而非 0.0.0.0 | 最小暴露原则，Docker 内部通过 kyb-net 访问，无需宿主机外部暴露 |
| 2026-05-25 | 优雅关闭 SIGTERM handler | 避免关闭过程中丢弃进行中的请求 |
| 2026-05-25 | SSRF 保护：UPSTREAM_URL 白名单校验 | 防止容器被用于 SSRF 攻击 |
| 2026-05-25 | Watch 进程独立于代理部署（宿主机 systemd） | 代理自身故障时 watch 仍能工作 |
| 2026-05-25 | Per-API-Key 速率限制（Token Bucket，60 req/min） | 防止单用户突发流量影响其他用户或打满 upstream 配额 |
| 2026-05-25 | Go 连接池显式配置 MaxIdleConns=100, MaxIdleConnsPerHost=50 | 高并发场景下确保连接复用效率，避免 TCP 连接频繁建立/拆除 |
| 2026-05-25 | 容器内存限制统一设为 256MB | 性能审查要求：容器限制、健康检查阈值、内存预算需一致 |
| 2026-05-25 | CK retry buffer 加 MAX_RETRY_BUFFER_BYTES=64MB 双重限制 | 同时约束条数（1000）和字节数（64MB），防止异常场景下 buffer 撑爆内存 |

### D. 未解决问题（待 Phase 1 设计）

1. **API key 统一管理** — 当前各容器各自持有 DeepSeek API key，代理无法统一管理。未来是否需要代理集中管理 key？
2. **缓存策略** — 相同 prompt 是否返回缓存结果？对于调试场景不合适，对成本敏感场景有价值。需要更明确的需求。
3. **采样率** — 是否需要支持采样（如只记录 10% 的请求）用于降本？
4. **请求审计与 replay** — 能否从 CK 中提取请求，重新发送到 DeepSeek？功能上可行，但需要额外的 replay 工具。
5. **sing-box mirror 集成** — 方案 B（sing-box）作为副产物，需要确定其配置、部署和与代理的数据关联方式。暂定 Phase 1 并行设计。
6. **watch 进程容灾** — watch 进程自身宕机时，需要冗余设计。当前暂定 watch 进程通过 systemd 自动重启 + 人工巡检兜底。

---

> **本文件由 boss 设计，Claude Code (DeepSeek) 编写，人审通过后进入 Phase 1 测试方案阶段。**
>
> ／人◕ ‿‿ ◕人＼
