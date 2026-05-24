# DeepSeek API Proxy Test Plan

> Issue: https://git.leyantech.com/quick-n-dirty/kyb/-/issues/169
> Status: Phase 1 — 测试方案审查
> 等级: **META-INFRA**（出问题 = 所有人断网）
>
> **铁律：本测试方案经 10 人审查通过前，任何人不得写任何代码。**

---

## 目录

1. [Mock DeepSeek Server](#1-mock-deepseek-server)
2. [测试用例分类](#2-测试用例分类)
3. [测试分层](#3-测试分层)
4. [灰度验收标准](#4-灰度验收标准)
5. [附录](#5-附录)

---

## 1. Mock DeepSeek Server

### 1.1 设计目标

Mock DeepSeek Server 是测试方案的基础设施。它模拟 `api.deepseek.com/anthropic/v1/messages` 的 Anthropic 兼容接口，使测试不依赖外部网络和真实 API key，且能注入各种故障模式。

### 1.2 架构

```
┌──────────────────────────────────────────────────────────┐
│ Mock DeepSeek Server                                      │
│ Port: 18080                                               │
│ Language: Go (与代理同一语言，复用类型定义)                 │
│                                                           │
│ ┌────────────────────────────────────────────────────┐   │
│ │ Admin API (:18081)                                  │   │
│ │  POST /__admin/scenario — 设置响应场景               │   │
│ │  GET  /__admin/requests  — 查看收到的请求记录        │   │
│ │  POST /__admin/reset     — 重置所有状态              │   │
│ │  GET  /__admin/health    — Mock 自身健康检查          │   │
│ └────────────────────────────────────────────────────┘   │
│                                                           │
│ ┌────────────────────────────────────────────────────┐   │
│ │ Proxy API (:18080)                                  │   │
│ │  POST /anthropic/v1/messages — 接收转发请求          │   │
│ │  GET  /anthropic/v1/models   — 返回模型列表          │   │
│ └────────────────────────────────────────────────────┘   │
│                                                           │
│ ┌────────────────────────────────────────────────────┐   │
│ │ Scenario Engine                                      │   │
│ │  - 根据当前选中的场景决定响应行为                     │   │
│ │  - 支持场景预设和动态切换                            │   │
│ │  - 记录所有收到的请求用于验证                        │   │
│ └────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

### 1.3 核心接口

#### 1.3.1 代理 API（模拟 DeepSeek）

```
POST /anthropic/v1/messages
Host: localhost:18080
Content-Type: application/json
Authorization: Bearer sk-test-key

{
  "model": "deepseek-chat",
  "messages": [{"role": "user", "content": "hello"}],
  "stream": false
}
```

#### 1.3.2 管理 API

```
# 设置场景
POST /__admin/scenario
Content-Type: application/json

{
  "scenario": "happy_path_stream",
  "config": {
    "chunk_count": 5,
    "chunk_interval_ms": 100,
    "response_delay_ms": 200
  }
}

# 查看接收到的请求
GET /__admin/requests
→ [
    {
      "id": "req-001",
      "method": "POST",
      "path": "/anthropic/v1/messages",
      "headers": {"authorization": "Bearer sk-***"},
      "body": {"model": "deepseek-chat", ...},
      "received_at": "2026-05-25T12:00:00.000Z"
    }
  ]

# 重置状态
POST /__admin/reset
→ {"status": "reset", "requests_cleared": 42}
```

### 1.4 场景定义

#### 1.4.1 正常场景

| 场景 ID | 描述 | HTTP 状态码 | 响应类型 | 参数 |
|---------|------|-------------|----------|------|
| `happy_path_non_stream` | 正常非 streaming 响应 | 200 | JSON | `response_delay_ms: 200` |
| `happy_path_stream` | 正常 streaming 响应 | 200 | SSE | `chunk_count: 5, chunk_interval_ms: 100` |
| `fast_path_non_stream` | 极快非 streaming 响应 | 200 | JSON | `response_delay_ms: 5` |
| `empty_messages` | 空 messages 数组（关联 TC-BC01） | 200 | JSON | — |
| `reasoner_stream` | 含 reasoning_content 的 streaming（关联 TC-N09b） | 200 | SSE | `chunk_count: 5, has_reasoning: true` |
| `reasoner_non_stream` | 含 reasoning_content 的非 streaming（关联 TC-N09c） | 200 | JSON | `response_delay_ms: 200, has_reasoning: true` |

#### 1.4.2 故障注入场景

| 场景 ID | 描述 | 注入方式 |
|---------|------|----------|
| `http_429` | 限流响应 | 返回 429 + `Retry-After: 1` + DeepSeek 格式错误 body |
| `http_500` | 服务器内部错误 | 返回 500 + DeepSeek 格式错误 body |
| `http_502` | Bad Gateway | 返回 502 + DeepSeek 格式错误 body |
| `http_503` | Service Unavailable | 返回 503 + DeepSeek 格式错误 body |
| `connect_timeout` | TCP 连接超时 | 通过 blackhole 容器实现（目标端口无服务监听，内核返回 RST；或 iptables DROP 入站 SYN 使无响应），代理 dial 超时后返回 504 |
| `dns_failure` | DNS 解析失败 | Mock server 不可用，测试用无效 hostname 配置代理 |
| `tls_error` | TLS 握手失败 | Mock 返回非 TLS 响应（纯文本）到 TLS 端口 |
| `connection_reset` | 接收请求后立即 RST | 读取请求后关闭 TCP 连接（不返回任何响应） |
| `connection_drop_after_header` | 发送部分 header 后断连（关联 TC-A29） | 发送 `HTTP/1.1 200 OK\r\n` 后立即断连 |
| `slow_response` | 慢响应（10s 延迟） | `response_delay_ms: 10000`，超过代理 connect_timeout |
| `stall_after_first_chunk` | Streaming 首 chunk 后无后续数据 | 发送 1 个 chunk 后停止发送，保持连接不断 |
| `stall_mid_stream` | Streaming 中间停顿 30s | 发 2 个 chunk → 暂停 30s → 继续发送 |
| `partial_sse` | SSE 中途断开 | 发 2 个 chunk 后正常关闭连接（不发送 message_stop） |
| `invalid_sse_format` | 非法 SSE 格式 | 发送 `event: unknown\ndata: not-json\n\n` 等非标准行 |
| `invalid_sse_data` | SSE data 不是合法 JSON | `event: content_block_delta\ndata: {{broken-json}}\n\n` |
| `wrong_event_order` | SSE event 顺序错误 | 先发 `message_stop` 再发 `content_block_delta` |
| `huge_response` | 超大响应（>2MB） | 返回含大量 padding 的响应 body |
| `huge_delta_chunk` | 单个 delta chunk > 64KB | 单个 content_block_delta 含 500KB text |
| `empty_body_200` | 200 但 body 为空 | 返回 200 + Content-Length: 0 |
| `binary_body` | 返回非 UTF-8 二进制 | 返回 200 + 随机二进制 content |
| `wrong_content_type` | 声明 SSE 但返回 JSON | Content-Type: text/event-stream 但实际是完整 JSON |
| `random_errors` | 随机故障（概率可配） | `error_rate: 0.1` → 10% 请求返回 500 |
| `rate_limited_burst` | 短时大量限流 | 连续 10 个请求返回 429，之后再恢复正常 |
| `http_401` | 认证失败（关联 TC-A15） | 返回 401 + DeepSeek 格式 auth error body |
| `mid_stream_error` | Streaming 中途 HTTP 错误（关联 TC-A24） | 发送几个 chunk 后，在 streaming 中途返回 5xx 错误码 |
| `long_stream` | 可变长度 streaming | 根据 `chunk_count` 参数决定发送 chunk 数，支持动态长度 |
| `stream_with_ping` | Streaming 中插入 ping event | Streaming 过程中定期插入 `event: ping` 和 `data: {"t": timestamp}` |
| `unknown_error_type` | 未知错误类型 | 返回 `{"error": {"message": "unknown cause", "type": "unknown_error_type"}}`（非标准 error.type） |
| `http_302_redirect` | HTTP 302 重定向 | 返回 302 + `Location: https://evil.com`，无响应 body |
| `pattern_errors` | 确定性失败模式 | 按预设模式精确返回成功/失败，用于替代概率测试的 flake |

#### 1.4.3 响应模板

非 streaming 响应模板（Anthropic 兼容格式）：

```json
{
  "id": "msg_mock_001",
  "type": "message",
  "role": "assistant",
  "content": [
    {
      "type": "text",
      "text": "This is a mock response from DeepSeek proxy test."
    }
  ],
  "model": "deepseek-chat",
  "stop_reason": "end_turn",
  "stop_sequence": null,
  "usage": {
    "input_tokens": 10,
    "output_tokens": 15
  }
}
```

Streaming chunk 模板：

```
event: message_start
data: {"type":"message_start","message":{"id":"msg_mock_001","type":"message","role":"assistant","content":[],"model":"deepseek-chat","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}

event: message_stop
data: {"type":"message_stop"}
```

Reasoner 模型 streaming chunk（含 reasoning_content）：

```
event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" final answer","reasoning_content":"thinking step 1..."}}
```

DeepSeek 原生错误格式：

```json
{
  "error": {
    "message": "Rate limit exceeded",
    "type": "rate_limit_error"
  }
}
```

### 1.5 Config 结构

```go
// 伪代码 — 描述 Mock Server 的配置结构

// Scenario 定义一个测试场景
type Scenario struct {
    ID              string            // 场景标识
    Headers         map[string]string // 自定义响应 header
    ResponseDelay   time.Duration     // 响应前延迟
    StatusCode      int               // HTTP 状态码
    Body            json.RawMessage   // 静态响应 body（非 streaming 模式）
    SSEChunks       []Chunk           // SSE chunks（streaming 模式）
    ChunkInterval   time.Duration     // chunk 间隔
    ResetAfter      bool              // 发送后是否 reset 连接
    InjectError     string            // 注入错误类型（"reset", "stall", "partial", "wrong_order"）
    ErrorBody       json.RawMessage   // 错误响应的 body
    ErrorRate       float64           // 随机错误率（0.0 ~ 1.0）
    ResponseSize    int               // 响应大小（bytes, 0=默认）
    ChunkCount      int               // Streaming chunk 数量（0=默认）
}

// Chunk 定义一个 SSE chunk
type Chunk struct {
    Event string          // event 类型
    Data  json.RawMessage // data payload
}

// ReceivedRequest 记录 Mock Server 收到的请求（用于断言验证）
type ReceivedRequest struct {
    ID        string
    Method    string
    Path      string
    Headers   map[string]string
    Body      json.RawMessage
    ReceivedAt time.Time
}
```

### 1.6 运行时行为

```
Mock Server 启动
    │
    ▼
初始化默认场景: happy_path_non_stream
    │
    ▼
监听 :18080 (代理 API) 和 :18081 (管理 API)
    │
    ▼
每收到代理请求:
    1. 记录请求到 requests buffer（上限 10000 条，环形覆盖）
    2. 根据当前选中场景决定响应
    3. 如有 response_delay → sleep
    4. 返回配置的响应（状态码 + body / SSE chunks）
    │
    ▼
每收到管理 API 请求:
    - POST /__admin/scenario → 切换场景
    - GET  /__admin/requests  → 返回已记录的请求
    - POST /__admin/reset     → 清空 requests buffer + 重置为默认场景
```

---

## 2. 测试用例分类

### 2.1 正常路径（Normal Path）

#### 2.1.1 非 Streaming 请求/响应

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-N01 | 基本非 streaming 请求 | Mock 设为 `happy_path_non_stream` | POST `/v1/messages`，`stream: false` | 返回 200，body 为完整 Anthropic 格式 JSON |
| TC-N02 | 非 streaming 命中等响应 | Mock 设为 `happy_path_non_stream` | 同上，验证 `response_delay_ms: 200` | 200，代理增加延迟 < 5ms（代理引入延迟） |
| TC-N03 | 多轮对话非 streaming | Mock `happy_path_non_stream` | body 含 3 轮对话历史 | 200，返回完整响应 |
| TC-N04 | 长 prompt（接近但未超限） | Mock `happy_path_non_stream` | prompt 约 60KB | 200，CK 记录完整，truncated=0 |
| TC-N05 | system prompt + user message | Mock `happy_path_non_stream` | body 含 system 和 messages | 200，正常转发 |
| TC-N06 | 请求含自定义 anthropic-version | Mock `happy_path_non_stream` | header `anthropic-version: 2023-06-01` | 200，header 透传到上游 |
| TC-N06b | x-api-key header 转发 | Mock `happy_path_non_stream` | header `x-api-key: sk-test-key-001`（Claude SDK 默认行为） | 200，x-api-key 正确透传到 Mock（通过 Mock /__admin/requests 验证 header 值） |
| TC-N06c | 仅 x-api-key 的完整路径 | Mock `happy_path_non_stream`，header `x-api-key: sk-test-key-001`（无 Authorization header） | POST `/v1/messages` | 200，x-api-key 正确透传到 Mock，Mock /__admin/requests 验证 header |
| TC-N07 | GET /v1/models | Mock 返回模型列表 | GET `/v1/models` | 200，返回模型列表 JSON |
| TC-N07b | POST /v1/complete 兼容路径 | Mock `happy_path_non_stream` | POST `/v1/complete` | 200，路径正确映射到 /anthropic/v1/complete，返回 Anthropic 格式 JSON |

#### 2.1.2 Streaming 逐 chunk 透传

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-N08 | 基本 streaming 请求 | Mock `happy_path_stream` | POST `/v1/messages`，`stream: true` | SSE 响应，5 个 chunk 依次到达 |
| TC-N09 | Streaming chunk 顺序正确 | Mock `happy_path_stream` | 同上，记录每个 chunk 的 event 类型 | 顺序: message_start → content_block_start → content_block_delta(x3) → content_block_stop → message_delta → message_stop |
| TC-N09b | Reasoner 模型 reasoning_content 透传（streaming） | Mock `reasoner_stream`（含 reasoning_content） | POST streaming，模型设为 deepseek-reasoner | SSE 中含 reasoning_content 字段，代理透传到客户端 |
| TC-N09c | Reasoner 模型 reasoning_content 透传（非 streaming） | Mock `reasoner_non_stream`（含 reasoning_content） | POST 非 streaming，模型设为 deepseek-reasoner | 200，content 含 reasoning_content 字段，CK 记录中 reasoning_content 完整 |
| TC-N10 | Streaming 首 chunk 延迟验证 | Mock `happy_path_stream` | 记录请求到首 chunk 时间 | TTFT < 50ms（代理引入延迟） |
| TC-N11 | 每 chunk 零延迟转发 | Mock `happy_path_stream`（chunk_interval: 100ms） | 在客户端记录每 chunk 到达时间 | chunk 间隔 ≈ 100ms（偏差 < 10ms），证明代理无缓冲延迟 |
| TC-N12 | Flush 频率验证 | Mock `happy_path_stream`（50 chunks，interval 10ms） | 代理侧记录每次 Flush 时间 | 每 chunk 到达后 1ms 内调用 Flush() |
| TC-N13 | 大 chunk 数量 streaming | Mock 1000 chunks，interval 5ms | 完整接收所有 chunks | 全部到达，无丢失，无截断 |
| TC-N13b | SSE ping event 透传 | Mock 在 streaming 中插入 `event: ping\ndata: {"t": 123}\n\n` | 接收 streaming 响应 | ping event 被透传到客户端，不干扰正常 event 解析 |

#### 2.1.3 Streaming 停止后 CK 写入

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-N14 | message_stop 后 CK 写入 | Mock `happy_path_stream` | 完成完整 streaming，等待 1s | CK infra.api_logs 有一条记录，streaming=1，completion 完整 |
| TC-N15 | CK 写入含 TTFT | Mock `happy_path_stream` | 同上 | CK 记录中 ttft_ms > 0 |
| TC-N16 | CK 写入含完整 completion | Mock `happy_path_stream` | 同上 | response_body 为拼接后的完整文本 |
| TC-N17 | CK 写入含 usage 信息 | Mock `happy_path_stream` | 同上 | CK 记录中 prompt_tokens > 0，completion_tokens > 0 |

#### 2.1.4 并发请求

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-N18 | 10 并发非 streaming | Mock `happy_path_non_stream` | 10 个 goroutine 同时发请求 | 全部 200，平均延迟 < 300ms |
| TC-N19 | 5 并发 streaming | Mock `happy_path_stream` | 5 个 goroutine 同时发 streaming 请求 | 全部完整接收，无 chunk 交叉 |
| TC-N20 | 混合并发（streaming + 非 streaming） | Mock 随机分配 | 10 个 streaming + 10 个非 streaming 同时 | 全部完成，无互相影响 |

### 2.2 异常路径（Abnormal Path）

#### 2.2.1 DeepSeek 超时

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-A01 | 连接超时（加速模式: CONNECT_TIMEOUT=3s） | iptables DROP 入站 SYN（模拟无响应，非 connection refused） | POST `/v1/messages` | 3s 后代理返回 504，error="connect_timeout" |
| TC-A02 | Streaming 空闲超时（加速模式: IDLE_TIMEOUT=10s） | Mock `stall_after_first_chunk` | POST streaming 请求，首 chunk 后无数据 | 10s 后代理返回 504，error="idle_timeout" |
| TC-A03 | 非 streaming 总超时（加速模式: TOTAL_TIMEOUT_NON_STREAMING=5s） | Mock `slow_response`，配置 `response_delay_ms: 7000`（超过 5s） | POST `/v1/messages`（非 streaming） | 5s 后代理返回 504，error="total_timeout" |
| TC-A04 | Streaming 总超时（加速模式: TOTAL_TIMEOUT_STREAMING=30s） | Mock 配置 streaming 持续 35s | 持续接收并验证 | 30s 后代理停止转发，返回 504，已收 chunks 写入 CK |
| TC-A05 | DNS 解析失败 | 代理配置 `UPSTREAM_URL=https://invalid.example.com` | POST `/v1/messages` | 代理返回 502，error="dns_resolution_failed" |
| TC-A06 | TLS 握手失败 | Mock 端口返回纯文本而非 TLS | POST 并通过代理转发 | 代理返回 502，error="tls_handshake_failed" |

#### 2.2.2 DeepSeek 返回错误状态码

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-A07 | 429 限流 | Mock `http_429` | POST `/v1/messages` | 返回 429，body 为 Anthropic 格式错误 |
| TC-A08 | 500 服务器错误 | Mock `http_500` | POST `/v1/messages` | 返回 500，body 为 Anthropic 格式错误 |
| TC-A09 | 502 Bad Gateway | Mock `http_502` | POST `/v1/messages` | 返回 502，body 为 Anthropic 格式错误 |
| TC-A10 | 503 Service Unavailable | Mock `http_503` | POST `/v1/messages` | 返回 503，body 为 Anthropic 格式错误 |
| TC-A11 | 429 后等待 Retry-After | Mock `http_429`（含 Retry-After: 1） | 同上 | 响应含 Retry-After header |
| TC-A12 | 连续 429 不计入熔断 | Mock `rate_limited_burst`（10 次 429） | 连续发 10 个请求 | 全部 429，熔断器不 OPEN（429 不计入失败率） |

#### 2.2.3 错误格式转换

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-A13 | 429 错误格式转换 | Mock `http_429`（DeepSeek 原生格式） | POST, 检查响应 body | 返回 Anthropic 格式：`{"type":"error","error":{"type":"rate_limit_error","message":"Rate limit exceeded"}}` |
| TC-A14 | 500 错误格式转换 | Mock `http_500` | POST, 检查 body | Anthropic 格式：`{"type":"error","error":{"type":"api_error","message":"..."}}` |
| TC-A15 | 401 错误格式转换 | Mock 返回 401 + DeepSeek auth error | POST, 检查 body | Anthropic 格式：`{"type":"error","error":{"type":"authentication_error","message":"..."}}` |
| TC-A16 | 未知错误类型映射 | Mock 返回未知 error.type | POST, 检查 body | 映射为 `api_error`，状态码 502 |
| TC-A17 | 代理自身错误也格式转换 | 停止 Mock（连接被拒） | POST | Anthropic 格式错误（非 DeepSeek 原生格式） |

#### 2.2.4 Streaming 异常

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-A18 | SSE 中途断开 | Mock `partial_sse`（2 chunks 后断连） | POST streaming 请求 | 代理检测到连接断开，写入 CK，truncated=1，error="stream_interrupted" |
| TC-A19 | Streaming stall 后恢复（生产模式: IDLE_TIMEOUT=60s） | Mock `stall_mid_stream`（停 30s 后恢复） | POST streaming，等 60s | 代理在 idle_timeout（60s）内等待，30s 后恢复传输，请求完整完成 |
| TC-A20 | 非法 SSE 格式 | Mock `invalid_sse_format` | POST streaming | 代理返回 502，error="sse_parse_error" |
| TC-A21 | SSE data 非 JSON | Mock `invalid_sse_data` | POST streaming | 代理返回 502，error="sse_parse_error" |
| TC-A22 | SSE 乱序 event — 状态机转换检测 | Mock `wrong_event_order`（先 message_stop 再 delta） | POST streaming | 代理按 event type 序列顺序检测非法状态机转换（例如 message_start 后不能又来一个 message_start），乱序则 CK 记录 `out_of_order=1`，按收到顺序写入 completion |
| TC-A23 | 非 SSE Content-Type | Mock `wrong_content_type`（声明 SSE 但返回 JSON） | POST streaming | 代理按非 streaming path 处理，等待完整 body 后返回 |
| TC-A24 | Streaming 中返回错误 | Mock 在 streaming 中途返回 HTTP 错误码 | POST streaming | 代理检测到错误，停止转发，写入 CK（标记 error） |
| TC-A25 | 超大 delta chunk（> 64KB） | Mock `huge_delta_chunk`（500KB text） | POST streaming | bufio.Scanner 正常读取，转发成功，不截断 |
| TC-A26 | 200 空 body | Mock `empty_body_200` | POST streaming | 代理返回 200 + 空 body（或 502 视实现而定） |
| TC-A27 | 二进制 body | Mock `binary_body` | POST streaming | 代理不 crash，返回适当错误 |
| TC-A28 | Streaming 无 message_stop | Mock `partial_sse`（不发 message_stop） | POST, 等待 idle_timeout | idle_timeout 后断开，已收 chunks 写入 CK（truncated=1） |
| TC-A29 | 上游返回部分 header 后断连 | Mock `connection_drop_after_header` | POST streaming | 代理检测到上游连接异常断开，返回 502，error="upstream_disconnected" |

#### 2.3.1 熔断触发

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-CB01 | 20% 失败率触发 OPEN（确定性） | Mock `pattern_errors`，预设模式：每 4 个请求返回 1 个 500（25% 失败率），连续 40 个请求 | 连续发 40 个请求 | 正好 10 个失败，失败率 25% > 20%，熔断器进入 OPEN |
| TC-CB02 | 低于阈值不触发（确定性） | Mock `pattern_errors`，预设模式：每 10 个请求返回 1 个 500（10% 失败率），连续 50 个请求 | 连续发 50 个请求 | 正好 5 个失败，失败率 10% < 20%，熔断器保持 CLOSED |
| TC-CB03 | 样本不足不触发 | 只发 5 个请求，3 个失败（60% > 20% 但 total < 10） | 发 5 个请求 | 熔断器保持 CLOSED（min_request_count=10） |
| TC-CB04 | 滑动窗口过期重置（加速模式: CB_WINDOW_SIZE=30s） | 窗口内积累 8 个失败，等待 30s 后失败计数归零 | 等待 30s 后再发请求 | 失败率重新计算，熔断器不触发 |
| TC-CB05 | 429 不计入失败率 | Mock 返回 10 次 429 + 10 次 200 | 连续发 20 个请求 | 熔断器不 OPEN（429 不计入失败计数） |
| TC-CB06 | CK 写入失败不影响熔断 | 停掉 CK，Mock 正常返回 | 连续发请求 | 熔断器不 OPEN（CK 失败不计入熔断计数） |

#### 2.3.2 HALF-OPEN 探测

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-CB07 | HALF-OPEN 探测成功恢复（加速模式: CB_HALF_OPEN_TIMEOUT=10s） | 先让熔断器 OPEN → 等待 10s → Mock 恢复正常 | 发 1 个请求 | OPEN → 10s 后 HALF-OPEN → 探测请求成功 → CLOSED |
| TC-CB08 | HALF-OPEN 探测失败保持 OPEN（加速模式: CB_HALF_OPEN_TIMEOUT=10s） | 先让熔断器 OPEN → 等待 10s → Mock 仍返回 500 | 发 1 个请求 | OPEN → 10s 后 HALF-OPEN → 探测失败 → 回到 OPEN |
| TC-CB09 | HALF-OPEN 多次失败（加速模式: CB_HALF_OPEN_TIMEOUT=10s） | 同上，连续 3 次探测失败 | 每次等待 10s，尝试 3 次 | 保持 OPEN，half_open_max_retry=3 后是否继续探测取决于实现 |
| TC-CB10 | HALF-OPEN 期间请求快速失败 | 熔断器在 HALF-OPEN，探测请求进行中 | 同时发另一个请求 | 第二个请求直接快速失败（不排队等待探测结果） |

#### 2.3.3 熔断状态监控

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-CB11 | /readiness 暴露熔断状态 | 熔断器 OPEN | GET `/readiness` | 返回 503，body 含 `{"status": "open", "circuit_breaker": true}` |
| TC-CB12 | /healthz 始终正常 | 熔断器 OPEN | GET `/healthz` | 返回 200（healthz 不检查熔断状态） |
| TC-CB13 | 熔断器状态变化记录 | 连续操作触发 OPEN → HALF-OPEN → CLOSED | 观察日志 | 代理日志记录每次状态变更 |
| TC-CB14 | /metrics 暴露熔断状态 | 操作熔断器 | GET `/metrics` | `proxy_circuit_breaker_state` 正确反映状态（0=CLOSED, 1=HALF-OPEN, 2=OPEN） |

### 2.4 CK 写入测试

#### 2.4.1 正常写入

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-CK01 | 非 streaming 正常写入 CK | Mock `happy_path_non_stream` | POST 请求，等待 1s | CK infra.api_logs 有 1 条记录，status_code=200，streaming=0 |
| TC-CK02 | Streaming 正常写入 CK | Mock `happy_path_stream` | POST streaming，等 message_stop | CK 有 1 条记录，streaming=1，response_body 完整 |
| TC-CK03 | CK 写入含所有字段 | Mock `happy_path_non_stream` | 同上 | CK 记录含 timestamp, request_id, model, prompt_tokens, completion_tokens, latency_ms, status_code, request_body, response_body, streaming, truncated, error |
| TC-CK04 | api_key_prefix 正确提取 | Authorization: Bearer sk-abc123def456 | POST 请求 | CK 中 api_key_prefix="sk-abc12" |
| TC-CK04a | api_key_prefix 从 x-api-key 提取 | header `x-api-key: sk-abc123def456`（无 Authorization header） | POST 请求 | CK 中 api_key_prefix="sk-abc12" |
| TC-CK04b | x-api-key 优先于 Authorization | header `x-api-key: sk-xyz789...` + `Authorization: Bearer sk-abc123...` | POST 请求 | CK 中 api_key_prefix 从 x-api-key 提取（"sk-xyz78"），非 Authorization |
| TC-CK05 | 无 Authorization header | 不传 Authorization | POST 请求 | api_key_prefix="" |
| TC-CK06 | source_container 正确记录 | 从特定容器名发请求 | POST 请求 | source_container 匹配请求来源容器名 |
| TC-CK07 | 批量验证写入完整性 | Mock 正常，连续发 100 个请求 | 循环发 100 个 | CK 中正好 100 条记录，无丢失无重复 |

#### 2.4.2 CK 不可用（Fail-Open）

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-CK08 | CK 停掉后代理仍工作 | `docker stop clickhouse` | POST 请求 | 200，响应正常返回，CK 写入跳过 |
| TC-CK09 | CK 恢复后代理自动重连 | TC-CK08 后 `docker start clickhouse` | 等待恢复后发请求 | CK 写入恢复正常 |
| TC-CK10 | CK 写入超时不影响响应 | 模拟 CK 慢写入（延迟 > 2s） | POST 请求 | 响应正常返回，CK 写入跳过 |
| TC-CK11 | CK 写入失败 buffer 机制 | CK 停止，发 10 个请求 | 观察代理日志 | 代理 buffer 最多保留 1000 条 / 64MB，不阻塞响应 |
| TC-CK12 | CK 恢复后 buffer 补写（不阻塞新请求） | TC-CK11 后启动 CK | 等待 buffer 刷新时同时发起新请求 | 优先补写 buffer 中的记录，同时新请求正常处理（补写不阻塞新请求处理） |
| TC-CK13 | CK buffer 超限截断 | CK 长时间不可用，持续发请求超过 1000 条或 64MB | 持续发请求 | 超出部分丢弃，不占用内存 |

#### 2.4.3 优雅关闭 flush buffer

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-CK14 | SIGTERM 时 flush CK buffer | CK buffer 中有待写入记录（通过 Mock admin API 或注入方式确认 buffer 非空） | 发送 SIGTERM | 代理在退出前 flush buffer（最多 5s），通过 Mock admin API 查询 CK buffer 状态验证 flush 完成 |
| TC-CK15 | 关闭时超时强制退出 | CK 不可用，buffer 有数据 | 发送 SIGTERM | 5s 后强制退出，不阻塞 |
| TC-CK16 | 关闭时拒绝新请求 | 发送 SIGTERM 过程中 | 发新 POST 请求 | 返回 503 + "proxy shutting down" |

#### 2.4.4 buffer 超限截断

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-CK17 | request_body 超过 64KB 截断 | 发送 > 64KB prompt | POST 请求 | CK 中 request_body 截断，前 32KB + 后 32KB，truncated=1 |
| TC-CK18 | response_body 超过 128KB 截断（非 streaming） | Mock `huge_response`（> 128KB body） | POST 请求（非 streaming） | CK 中 response_body 截断，前 48KB + 后 48KB，truncated=1 |
| TC-CK18b | response_body 超过 128KB 截断（streaming） | Mock 配置 200 个 chunks 总计 > 256KB text | POST streaming 请求 | 单个 chunk 不截断，写入 CK 时拼接后 response_body 总量超过 128KB 则截断，streaming truncated=1 |
| TC-CK19 | 刚好达到边界不截断 | Mock 返回 128KB 响应（阈值 > 128KB 才截断） | POST 请求 | 不截断（截断条件为 response_body 大小 > 128KB，128KB 刚好不超过阈值，应完整保留） |
| TC-CK19b | UTF-8 字符边界截断 | 请求 body 含 4 字节 UTF-8 字符（如 emoji），总大小超过 64KB | POST 请求 | 截断在 UTF-8 字符边界，不产生乱码（截断点落在完整字符后） |
| TC-CK20 | PII 脱敏 | 请求 body 含 `"api_key": "sk-secret123"` | POST 请求 | CK 中 `[REDACTED]`，转发响应不脱敏 |
| TC-CK20b | x-api-key 值脱敏 | header `x-api-key: sk-supersecret` | POST 请求 | CK request_body 中 sk-supersecret 被 `[REDACTED]` 替换，转发响应不脱敏 |

### 2.5 性能基准（Performance）

**测量方法统一说明：** 内存使用统一使用 `docker stats` 采集容器 RSS（单位 MB），延迟测量统一使用 Go `runtime/metrics` 纳秒级时间戳。性能测试前必须有 5s warmup 阶段（发送 5 个预热请求），warmup 数据不计入统计。基准测试结果以 P50 / P99 / P999 分位报告。

#### 2.5.1 代理引入延迟

| 编号 | 名称 | 前置条件 | 步骤 | 测量指标 | 目标 |
|------|------|----------|------|----------|------|
| TC-P01 | 非 streaming 代理延迟 | Mock `fast_path_non_stream`（delay=5ms），直接测 Mock 得到基线，经代理再测 | 对比直接请求 Mock 和经代理请求 Mock 的延迟 | 代理引入额外延迟 P50 < 5ms, P99 < 20ms |
| TC-P02 | Streaming TTFT 代理延迟 | Mock `happy_path_stream`（delay=0） | 从请求发出到收到首 chunk 的时间 | P50 < 50ms, P99 < 200ms |
| TC-P03 | 每 chunk Flush 延迟 | Mock 100 chunks，interval 10ms | 通过 admin metrics endpoint 暴露 `proxy_flush_duration`，测量从收到 chunk 到 Flush 返回的时间 | P50 < 1ms, P99 < 5ms |
| TC-P04 | CK 写入对响应的影响 | Mock `happy_path_non_stream`，开启和关闭 CK 写入对比 | 对比两组的响应延迟 | CK 写入不增加响应延迟（异步 goroutine 零阻塞） |

#### 2.5.2 吞吐量

| 编号 | 名称 | 前置条件 | 步骤 | 目标 |
|------|------|----------|------|------|
| TC-P05 | 200 并发非 streaming | Mock `fast_path_non_stream` | 200 goroutines 同时 POST | 全部 200 OK，无 connection reset |
| TC-P06 | 1000 req/s 吞吐 | Mock `fast_path_non_stream`（1KB 响应） | 持续施压 | 吞吐 >= 1000 req/s |
| TC-P07 | 50 并发 streaming | Mock `happy_path_stream`（30s 持续） | 50 goroutines 同时 streaming | 全部完整接收，无 chunk 丢失 |
| TC-P08 | 混合负载 | 80% 非 streaming + 20% streaming | 总量 100 req/s 持续 1 分钟 | 全部完成，无错误 |

#### 2.5.3 内存使用

| 编号 | 名称 | 前置条件 | 步骤 | 目标 |
|------|------|----------|------|------|
| TC-P09 | 空载内存 | 无请求 | 启动后等待 10s，测量 RSS | < 20MB |
| TC-P10 | 200 并发内存 | TC-P05 的同时 | 在 200 并发期间测量 RSS | < 128MB（256MB limit 的 50%） |
| TC-P11 | SSE buffer 内存 | 50 并发 streaming，每个 2MB buffer | 持续 30s | SSE buffer 总量 < 100MB |
| TC-P12 | 长时间运行内存泄漏 | 持续发送请求 1 小时 | 每 5 分钟记录 RSS | RSS 无持续增长趋势 |
| TC-P13 | goroutine 泄漏检查 | 持续发送请求 1 小时 | 每 5 分钟记录 goroutine 数 | goroutine 数稳定，无泄漏 |

### 2.6 速率限制（Rate Limiting）

#### 2.6.1 Per-API-Key 限流

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-RL01 | 单 key 超过 60 req/min | 用同一个 API key 发 61 个请求（间隔 < 1s） | 快速连续发 61 个请求 | 第 61 个返回 429 |
| TC-RL02 | 不同 key 独立限流 | 用 key-A 发 60 个，key-B 发 60 个 | 并行用两个 key | 两个 key 各自限流，互不影响 |
| TC-RL03 | 限流后恢复 | 被限流的 key 等待 1 分钟后 | 再发请求 | 恢复正常（令牌桶恢复） |
| TC-RL04 | 无 Authorization key 限流 | 不用 auth header 发 61 个请求 | 快速连续发 | 第 61 个返回 429（anonymous key 限流） |
| TC-RL05 | 429 响应格式 | 触发限流 | 检查响应 | Anthropic 格式 429 + `Retry-After: 1` |
| TC-RL06 | 限流不计入熔断 | 触发限流获得 429 | 检查熔断器状态 | 熔断器保持 CLOSED |
| TC-RL07 | 限流 key 自动清理 | 用某个 key 发请求，等待 5 分钟无活动 | 检查内部状态 | 该 key 的令牌桶被清理（内存不泄漏） |
| TC-RL08 | 限流 key 使用 SHA256 hash | Authorization: Bearer sk-abc123def456ghi7 | 触发限流 | 限流 key 为完整 key 的 SHA256 hash，而非前缀 "sk-abc12"（避免前缀碰撞） |

### 2.7 安全测试

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-SEC01 | SSRF 白名单校验 | 配置 `UPSTREAM_URL=https://evil.com` | 启动代理 | 代理拒绝启动，log error |
| TC-SEC02 | SSRF 白名单子域名 | 配置 `UPSTREAM_URL=https://api.deepseek.com.evil.com` | 启动代理 | 代理拒绝启动 |
| TC-SEC03 | PII 脱敏关键词 | request body 含 `"password": "supersecret"` | POST 请求 | CK 中 `[REDACTED]` |
| TC-SEC04 | PII 脱敏嵌套字段 | request body 含 `{"config": {"api_key": "sk-xxx"}}` | POST 请求 | 嵌套字段也脱敏 |
| TC-SEC05 | PII 脱敏不修改转发 | 同上 | 检查转发到 Mock 的请求 | 转发内容保持原始值，不做脱敏 |
| TC-SEC06 | PII_KEYWORDS 可配置 | 设置 `PII_KEYWORDS=custom_keyword` | body 含 `custom_keyword` | 脱敏生效 |
| TC-SEC07 | 端口不暴露外部 | `netstat -tln` 检查 | 代理运行中 | `:2082` 绑定 `127.0.0.1` 而非 `0.0.0.0` |
| TC-SEC08 | API key 不完整落盘 | Authorization 含完整 key | 检查 CK 记录 | CK 只存前 8 位，不存完整 key |
| TC-SEC09 | 超大 body 防止 DoS | 发送 100MB request body | POST | 代理拒绝或截断，不 OOM |
| TC-SEC10 | SSRF 重定向跟随 | 配置 `UPSTREAM_URL=https://api.deepseek.com`，Mock 返回 302 到 `https://evil.com` | POST 请求 | 代理不跟随重定向到白名单外 URL，返回 502 |
| TC-SEC11 | SSRF IP 地址绕过 | 配置白名单含 `deepseek.com`，但使用 `http://192.168.1.1`（白名单中域名的 IP） | POST 请求 | 代理 DNS 解析后校验 IP 是否匹配白名单，拒绝非白名单 IP |
| TC-SEC12 | 代理日志 PII 脱敏 | 请求含敏感字段（password, token, api_key） | 观察代理 stdout/stderr 日志 | 代理自身日志不打印完整 API key 和敏感字段值，仅输出 `[REDACTED]` |

| TC-SEC13 | DNS rebinding 攻击 | 配置 `UPSTREAM_URL=https://attacker-controlled.com`，该域名 DNS 先返回合法 IP 再返回恶意 IP | 启动代理后发请求 | 代理在 DNS 解析后校验 IP 是否匹配白名单，拒绝 DNS rebinding（仅首次解析有效） |
| TC-SEC14 | IPv6 SSRF 绕过 | 配置白名单含 `deepseek.com`，但使用 IPv6 地址绕过白名单校验 | POST 请求（目标使用 IPv6 地址） | 代理校验 IPv6 地址是否匹配白名单，不匹配则拒绝 |
| TC-SEC15 | IP 混淆表示绕过 | 使用十进制/十六进制/八进制 IP 表示法（例如 `http://0x7f000001` 或 `http://2130706433`） | POST 请求 | 代理正确解析非常规 IP 格式，拒绝非白名单 IP |

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-GC01 | SIGTERM 正常关闭 | 无进行中请求 | 发送 SIGTERM | 代理在 1s 内退出，exit 0 |
| TC-GC02 | SIGTERM 时进行中非 streaming | 1 个非 streaming 请求进行中 | 发送 SIGTERM | 请求完成，响应返回后再退出 |
| TC-GC03 | SIGTERM 时进行中 streaming | 1 个 streaming 请求进行中 | 发送 SIGTERM | streaming 完成后退出，或 idle_timeout 后退出 |
| TC-GC04 | 关闭期间新请求 | SIGTERM 后立即发新请求 | 同上 + 新请求 | 新请求 503 |
| TC-GC05 | SIGINT 同 SIGTERM | 同 TC-GC01 | 发送 SIGINT | 同 SIGTERM 行为 |
| TC-GC06 | Watch 进程检测到代理宕机 | 停止代理容器 | 观察 Watch 日志和共享状态 | Watch 在 3s 内检测到，记录 unhealthy |
| TC-GC07 | Watch 进程自动 fallback | 模拟代理连续 4 次健康检查失败 | 观察 Watch 日志 | Watch 执行 ANTHROPIC_BASE_URL 直连切换 |
| TC-GC08 | Watch 进程自动恢复 | TC-GC07 后启动代理 | 等待代理健康持续 30s | Watch 自动切回代理 URL |
| TC-GC09 | Watch 与熔断器联动 | 熔断器 OPEN → Watch 检测到 | 观察 | Watch 在熔断 OPEN 超过一定时间后执行 fallback |
| TC-GC10 | Watch 进程自身不掉 | 向 Watch 发 SIGTERM | 观察 | systemd 自动重启 Watch |

### 2.9 边界条件与配置

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-BC01 | 空请求 body | Content-Length: 0 | POST 空 body | 代理返回 400 或透传（取决于 DeepSeek 行为） |
| TC-BC02 | 非法 JSON body | body: `{broken json}` | POST | 代理返回 400 |
| TC-BC03 | 超大 header | 发送 > 64KB header | POST | 代理正常处理或返回 431 |
| TC-BC04 | 不支持的 HTTP 方法 | PUT `/v1/messages` | PUT | 返回 405 Method Not Allowed |
| TC-BC05 | 不存在的路径 | POST `/v1/unknown` | POST | 代理透传到 DeepSeek（返回 DeepSeek 的 404） |
| TC-BC06 | 配置错误启动校验 | 设置 `LISTEN_ADDR=:999999` | 启动代理 | 代理启动失败，log error，exit non-zero |
| TC-BC07 | 无效 UPSTREAM_URL | 设置空 UPSTREAM_URL | 启动代理 | 代理启动失败 |
| TC-BC08 | 内容截断信息完整 | response 尾部含 usage | 截断发生后检查 CK | `${RESPONSE_BODY_END}` 含 usage 信息（未被截断） |
| TC-BC09 | 长连接复用 | 连续 50 个请求复用同一 TCP 连接（Keep-Alive） | 从同一客户端发 50 个请求 | 全部成功，代理连接池复用计数增加 |

### 2.10 客户端断连（Client Disconnect）

| 编号 | 名称 | 前置条件 | 步骤 | 预期结果 |
|------|------|----------|------|----------|
| TC-DC01 | 客户端 Ctrl+C 中断 streaming | Mock `happy_path_stream`，客户端通过 streaming 接收中 | 在收到 2 个 chunk 后客户端发送 SIGINT | 代理检测客户端断连，释放 goroutine 和连接资源，已收 chunks 写入 CK（truncated=1） |
| TC-DC02 | 客户端终端关闭 | Mock `happy_path_stream`，客户端通过 streaming 接收中 | 关闭客户端终端/Tab 页 | 代理在 TCP 连接 RST 后检测到断连，释放资源，已收 chunks 写入 CK |
| TC-DC03 | 客户端网络闪断 | Mock `happy_path_stream`，客户端通过 streaming 接收中 | 使用 `iptables -C OUTPUT -p tcp --dport 2082 -j DROP 2>/dev/null || iptables -A OUTPUT -p tcp --dport 2082 -j DROP` 模拟，t.Cleanup 中 `iptables -D OUTPUT -p tcp --dport 2082 -j DROP` | 代理在 TCP keepalive 超时或写入失败后检测到断连，释放资源，已收 chunks 写入 CK（truncated=1） |

---

## 3. 测试分层

### 3.1 层级定义

| 层级 | 范围 | 运行方式 | 时间 | 触发时机 | 环境 |
|------|------|---------|------|----------|------|
| **Unit** | 单个函数 / 模块逻辑 | `go test ./...` | 毫秒级 | CI 每次 push | 纯 Go 测试，无外部依赖 |
| **Integration** | Mock Server ↔ 代理 ↔ CK | `docker compose up` + `go test -tags=integration` | 秒级 | CI 每次 push（或 PR） | Docker Compose 含 Mock + 代理 + CK |
| **E2E** | 代理 ↔ 真实 DeepSeek | 手动执行脚本 | 分钟级 | 部署前 / 发布时 | 生产环境或 staging |
| **Chaos** | 全链路 + 故障注入 | chaos pipeline / 手动 | 分钟级 | 发布前 / 定期 | Docker Compose + 网络工具 |

### 3.2 Unit 测试

#### 3.2.1 范围

所有不依赖外部网络、数据库或其他服务的纯逻辑函数。

| 模块 | 测试内容 | 用例数 |
|------|----------|--------|
| SSE 解析器 | 行解析、event 提取、data 解析 | ~15 |
| 错误格式转换 | DeepSeek 格式 → Anthropic 格式 | ~10 |
| 截断逻辑 | 64KB/128KB 边界截断，前后保留 | ~8 |
| PII 脱敏 | 关键词匹配、嵌套字段、自定义关键词 | ~12 |
| 熔断器滑动窗口 | 环形数组、计数、状态转换 | ~15 |
| SSRF 白名单 | 域名校验、精确匹配、子域名 | ~10 |
| Token Bucket 限流 | 桶填充、消费、超时清理 | ~10 |
| 客户端 IP 提取 | X-Forwarded-For, X-Real-IP | ~6 |
| 请求 ID 生成 | UUID 格式、唯一性 | ~3 |
| URL 路径映射 | /v1/messages → /anthropic/v1/messages 等 | ~8 |

#### 3.2.2 运行方式

```bash
# 所有 unit test
go test ./... -v -race -coverprofile=coverage.out

# 无需外部依赖，纯 Go 测试
# 预期: < 1s
# 覆盖率目标: > 80%
```

#### 3.2.3 测试框架选择

使用 Go 标准库 `testing` + `testify/assert`。无需 mock 框架——通过 interface 注入 mock 依赖。

```
无需 mock 框架的理由：
- Go 的 interface + struct embedding 已足够
- 代理的核心逻辑是函数式的（输入 → 处理 → 输出）
- 减少外部依赖，保持二进制体积小
- 团队对 testify 最熟悉
```

#### 3.2.4 关键 Unit 测试示例（仅描述，不写代码）

```
SSE Parser Unit Test:
  - 输入: 标准 SSE 行序列
  - 验证: 正确解析出 event 类型和 data payload

SSE Parser 异常输入:
  - 输入: 空行、非法 event、连续 data
  - 验证: 不 panic，返回合适错误

错误格式转换:
  - 输入: DeepSeek 429 响应 body
  - 验证: 输出正确的 Anthropic 格式（含 type 包装）

截断逻辑:
  - 输入: 70KB request_body + 140KB response_body
  - 验证: request_body 截断为前后 32KB，response_body 截断为前后 48KB

PII 脱敏:
  - 输入: {"token": "sk-xxx", "nested": {"key": "value"}}
  - 验证: 递归匹配，所有匹配字段值替换为 [REDACTED]
```

### 3.3 Integration 测试

#### 3.3.1 架构

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Test Runner      │     │  Mock DeepSeek   │     │  ClickHouse      │
│  (go test -tags=  │────▶│  Server          │     │  (port 9000)     │
│   integration)    │     │  (port 18080)    │     │                  │
│                   │     └──────────────────┘     └──────────────────┘
│  - 发送 HTTP 请求  │              ▲                        ▲
│  - 断言响应        │              │                        │
│  - 查询 CK 验证    │     ┌──────────────────┐              │
│  - 管理 Mock 场景  │────▶│  Proxy Under     │──────────────┘
│                   │     │  Test            │
│                   │     │  (port 2082)     │
└──────────────────┘     └──────────────────┘
```

#### 3.3.2 启动方式

```yaml
# docker-compose.test.yml
version: "3.8"
services:
  mock-deepseek:
    build:
      context: .
      dockerfile: test/mock/Dockerfile
    ports:
      - "18080:18080"
      - "18081:18081"

  proxy:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "2082:2082"
      - "2083:2083"
    environment:
      - LISTEN_ADDR=:2082
      - UPSTREAM_URL=http://mock-deepseek:18080/anthropic/v1/messages
      - UPSTREAM_URL_WHITELIST=mock-deepseek
      - CK_DSN=clickhouse://clickhouse:9000/infra
      - CONNECT_TIMEOUT=3s
      - IDLE_TIMEOUT=10s
      - TOTAL_TIMEOUT_NON_STREAMING=5s
      - TOTAL_TIMEOUT_STREAMING=30s
      - CB_WINDOW_SIZE=5m
      - CB_FAILURE_RATE=20
      - CB_MIN_REQUEST_COUNT=10
      - CB_HALF_OPEN_TIMEOUT=30s
      - PII_MASK_ENABLED=true
      - PII_KEYWORDS=token,password,secret,key,credential,authorization
      - RATE_LIMIT_REQUESTS_PER_MIN=60
      - MAX_BUFFER_SIZE=2MB
      - SCANNER_BUFFER_SIZE=1MB
    depends_on:
      - mock-deepseek
      - clickhouse

  clickhouse:
    image: clickhouse/clickhouse-server:latest
    ports:
      - "9000:9000"
    environment:
      - CLICKHOUSE_DB=infra
    volumes:
      - ./test/ck-init:/docker-entrypoint-initdb.d  # 初始化 infra.api_logs 表

  test-runner:
    build:
      context: .
      dockerfile: test/runner/Dockerfile
    depends_on:
      - proxy
      - mock-deepseek
      - clickhouse
    environment:
      - PROXY_URL=http://proxy:2082
      - MOCK_ADMIN_URL=http://mock-deepseek:18081
      - CK_DSN=clickhouse://clickhouse:9000/infra
    command: ["go", "test", "./test/integration/...", "-v", "-tags=integration", "-timeout=300s"]
```

#### 3.3.3 Integration 测试场景

| 场景 | 涵盖的 TC | 预计执行时间 |
|------|-----------|-------------|
| 正常非 streaming 路径（含 /anthropic/v1/messages, /v1/models, /v1/complete） | TC-N01 ~ TC-N07b | ~5s |
| 正常 streaming 路径 | TC-N08 ~ TC-N17 | ~15s |
| 并发请求 | TC-N18 ~ TC-N20 | ~10s |
| 超时处理 | TC-A01 ~ TC-A06 | ~70s（含超时等待） |
| 错误状态码 | TC-A07 ~ TC-A12 | ~5s |
| 错误格式转换 | TC-A13 ~ TC-A17 | ~5s |
| Streaming 异常 | TC-A18 ~ TC-A29 | ~90s（含 stall 等待） |
| 熔断器 | TC-CB01 ~ TC-CB14 | ~120s（含 30s 等待） |
| CK 写入 | TC-CK01 ~ TC-CK20 | ~30s |
| 速率限制 | TC-RL01 ~ TC-RL08 | ~30s |
| 安全 | TC-SEC01 ~ TC-SEC09 | ~10s |
| 优雅关闭 | TC-GC01 ~ TC-GC05 | ~10s |
| 边界条件 | TC-BC01 ~ TC-BC09 | ~10s |
| **合计** | | **~410s（约 7 分钟）** |

运行说明：
- 长等待测试（超时、熔断 30s 等待）可使用 `t.Parallel()` 并行执行，减少总时间
- 预计并行运行后总时间 ~3 分钟
- CI 超时设为 5 分钟

#### 3.3.4 CK 初始化 SQL

```sql
-- test/ck-init/init.sql
CREATE TABLE IF NOT EXISTS infra.api_logs (
    timestamp           DateTime64(3),
    request_id          String,
    trace_id            String DEFAULT '',
    model               LowCardinality(String),
    api_key_prefix      FixedString(8) DEFAULT '',
    client_ip           String DEFAULT '',
    source_container    String DEFAULT '',
    prompt_tokens       UInt32,
    completion_tokens   UInt32,
    latency_ms          UInt32,
    ttft_ms             UInt32,
    status_code         UInt16,
    streaming           UInt8,
    request_body        String DEFAULT '',
    response_body       String DEFAULT '',
    truncated           UInt8 DEFAULT 0,
    error               String DEFAULT '',
    cached              UInt8 DEFAULT 0,
    retry_count         UInt8 DEFAULT 0
) ENGINE = MergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, model, status_code)
TTL timestamp + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

#### 3.3.5 Integration 测试结构（仅描述）

```
test/integration/
├── main_test.go              # TestMain: 等待所有服务就绪
├── suite_normal_test.go      # 正常路径测试套件
├── suite_abnormal_test.go    # 异常路径测试套件  
├── suite_circuit_breaker_test.go  # 熔断测试套件
├── suite_ck_test.go          # CK 写入测试套件
├── suite_rate_limit_test.go  # 速率限制测试套件
├── suite_security_test.go    # 安全测试套件
├── suite_graceful_test.go    # 优雅关闭测试套件
├── suite_edge_test.go        # 边界条件测试套件
└── helpers/
    ├── client.go             # HTTP 客户端封装
    ├── mock_admin.go         # Mock 管理 API 封装
    └── ck_client.go          # CK 查询封装
```

### 3.4 E2E 测试

#### 3.4.1 范围

E2E 测试使用真实 DeepSeek API（dry-run 模式），验证代理在实际网络环境下的行为。

**重要：E2E 测试使用真实 API key 和 DeepSeek，会产生实际费用。默认跳过，手动触发。**

```bash
# E2E 测试执行
DEEPSEEK_API_KEY=sk-... go test -tags=e2e -run TestE2E ./test/e2e/ -v
```

#### 3.4.2 测试场景

| 场景 | 步骤 | 成功率 | 费用 |
|------|------|--------|------|
| 非 streaming （dry-run，最大 tokens=1） | POST 请求，`max_tokens: 1` | 应 100% | ~￥0.001/次 |
| Streaming （dry-run，最大 tokens=1） | POST `stream: true, max_tokens: 1` | 应 100% | ~￥0.001/次 |
| models 列表 | GET `/v1/models` | 应 100% | 免费 |

#### 3.4.3 Dry-Run 原则

- `max_tokens: 1` 最小化费用和延迟
- 每次 E2E 测试费用预算 < ￥0.01
- E2E 不通时排查顺序：网络连通性 → 代理日志 → CK 写入 → DeepSeek 状态

### 3.5 Chaos 测试

#### 3.5.1 环境

Chaos 测试在 Integration 环境（docker-compose）基础上，使用网络工具注入故障。

```bash
# Chaos 测试启动
docker compose -f docker-compose.test.yml up -d
# 注入网络故障到 proxy 容器（使用 replace 而非 add，确保幂等）
docker exec proxy tc qdisc replace dev eth0 root netem loss 10%
# 运行 chaos 测试（测试中应通过 t.Cleanup() 自动恢复网络配置）
go test -tags=chaos ./test/chaos/ -v
# 清理（t.Cleanup 已自动执行，也可手动执行）
docker exec proxy tc qdisc del dev eth0 root 2>/dev/null || true
```

#### 3.5.2 Chaos 场景

| 场景 | 注入方式 | 覆盖的 TC |
|------|----------|-----------|
| **断网 10s** | `iptables -C OUTPUT -d mock-deepseek -j DROP 2>/dev/null || iptables -A OUTPUT -d mock-deepseek -j DROP`，t.Cleanup 中 `iptables -D OUTPUT -d mock-deepseek -j DROP`（幂等添加） | TC-CB01（熔断触发），TC-GC06（Watch fallback） |
| **DNS 故障 30s** | 修改 proxy 容器的 `/etc/hosts`，mock-deepseek 指向 10.0.0.1 | TC-A05（DNS 失败） |
| **延迟抖动 1s ±500ms** | `tc qdisc replace dev eth0 root netem delay 1000ms 500ms`（幂等 replace） | TC-A03（超时） |
| **随机丢包 10%** | `tc qdisc replace dev eth0 root netem loss 10%`（幂等 replace） | TC-CB01（熔断），TC-P04（代理延迟） |
| **带宽限制 100Kbps** | `tc qdisc replace dev eth0 root tbf rate 100kbps burst 10k`（幂等 replace） | TC-P04（延迟测量） |
| **CK 容器停止** | `docker stop clickhouse` | TC-CK08 ~ TC-CK13（CK fail-open） |
| **CK 容器恢复** | `docker start clickhouse` | TC-CK09（自动恢复） |
| **代理 OOM 模拟** | `docker update --memory=64m proxy` + 发大请求；恢复：`docker update --memory=256m proxy`（t.Cleanup） | TC-P11（内存超限截断） |
| **端口冲突** | 先在 :2082 启动一个 nc 监听，再启动代理 | TC-BC06（启动失败） |
| **时钟跳跃** | `docker exec proxy date -s "+1 hour"`；恢复：`docker exec proxy chronyd -q` 或 `ntpdate -u pool.ntp.org`（t.Cleanup） | 代理延迟计算不受影响（monotonic clock） |

#### 3.5.3 「星期五下午」综合压力场景

```
Chaos Scenario: "星期五下午"
- 50 个并发虚拟用户，各发 20 个请求
- 10% 概率 Mock 返回 429
- 5% 概率 Mock 超时（connect_timeout）
- 5% 概率 CK 写入慢（延迟 > 2s）
- 持续 5 分钟

验证目标:
1. 所有请求最终被回应（成功或适当错误码）
2. 熔断器不误触发（429 不计入，5% 超时未达 20% 阈值）
3. CK 日志不丢失（除写入失败丢弃的）
4. P99 延迟不超过无代理时 + 500ms

退出条件:
- 所有请求已响应（无 hanging）
- 熔断器保持 CLOSED（或短暂 OPEN 后恢复）
- CK 日志完整率 > 95%
- 代理内存 < 192MB
```

---

## 4. 灰度验收标准

### 4.1 验收标准总览

每个 Phase 对应一组 Gate，Gate 通过才能进入下一 Phase。Gate 分为三类：

| 类型 | 含义 | 未通过处理 |
|------|------|-----------|
| **MANDATORY** | 必须通过，否则阻塞 | 必须修复后才能继续 |
| **TOLERANCE** | 允许一定偏差，但需记录 | 记录偏差值，持续监控 |
| **OBSERVE** | 仅观察，不阻塞 | 记录到监控面板 |

### 4.2 Phase 0：空跑验证（部署代理但不改 Claude 配置）

**目标：确认代理自身功能正常，不产生 side effect。**

| Gate | 检查项 | 标准 | 类型 | 验证方式 |
|------|--------|------|------|----------|
| G-0.1 | 代理启动 | 代理进程启动，健康检查 200 | MANDATORY | `curl -f http://localhost:2082/healthz` |
| G-0.2 | 代理就绪 | `/readiness` 返回 200 | MANDATORY | `curl -f http://localhost:2083/readiness` |
| G-0.3 | 手动 curl 转发 | POST 到代理，能收到 DeepSeek 响应 | MANDATORY | `curl -x http://localhost:2082 ...` |
| G-0.4 | CK 写入 | POST 后 CK infra.api_logs 有记录 | MANDATORY | CK 查询确认 |
| G-0.5 | 非 streaming 响应 | 响应 body 完整，Anthropic 格式 | MANDATORY | 手动验证 |
| G-0.6 | Streaming 响应 | SSE chunks 完整，顺序正确 | MANDATORY | 手动验证 |
| G-0.7 | PII 脱敏 | CK 中敏感字段已脱敏 | MANDATORY | 检查 CK 记录 |
| G-0.8 | 错误格式转换 | 模拟 429 返回 Anthropic 格式 | MANDATORY | curl 验证 |
| G-0.9 | 代理引入延迟 | P50 < 50ms，P99 < 200ms | TOLERANCE | `curl -w "%{time_total}"` 对比 |
| G-0.10 | 内存使用 | RSS < 100MB（空载） | TOLERANCE | `docker stats` 观察 |
| G-0.11 | 长时间运行 | 连续 24 小时无 crash | MANDATORY | 后台运行观察 |
| G-0.12 | CK 自动建表 | 首次启动自动创建 infra.api_logs | MANDATORY | 检查表是否存在 |

**Phase 0 退出条件：G-0.1 ~ G-0.12 全部 MANDATORY 通过，TOLERANCE 项记录基线。**

### 4.3 Phase 1：切一个非关键容器

**目标：在真实流量下验证代理的稳定性和性能。**

**前置条件：Phase 0 全部通过。**

| Gate | 检查项 | 标准 | 类型 | 验证方式 |
|------|--------|------|------|----------|
| G-1.1 | 测试 sandbox 正常对话 | 通过代理的 Claude 正常回答问题 | MANDATORY | 手动测试 |
| G-1.2 | CK 实时写入 | 每次对话都在 CK 有记录 | MANDATORY | CK 查询 |
| G-1.3 | 代理延迟 | P99 延迟 < 无代理时 + 200ms | MANDATORY | Grafana 面板 |
| G-1.4 | 无新增错误 | 代理不引入额外错误（错误率 < 0.1%） | MANDATORY | Grafana 对比上线前后 |
| G-1.5 | 熔断器状态 | 熔断器保持 CLOSED | MANDATORY | /metrics 检查 |
| G-1.6 | 观察 24 小时 | 无 crash，无 OOM，无异常 | MANDATORY | docker logs + docker stats |
| G-1.7 | 测试 sandbox 无感知 | 用户不觉得变慢 | TOLERANCE | 用户反馈 |
| G-1.8 | 代理内存 | 高峰 < 128MB | TOLERANCE | `docker stats` 记录 |

**Phase 1 退出条件：G-1.1 ~ G-1.6 全部通过，稳定运行 24 小时无问题。**

### 4.4 Phase 2：切 boss 容器（最高风险）

**目标：验证关键路径的可靠性，确认熔断和 Fallback 机制有效。**

**前置条件：Phase 1 全部通过，且 24 小时观察期无问题。**

| Gate | 检查项 | 标准 | 类型 | 验证方式 |
|------|--------|------|------|----------|
| G-2.1 | Boss 容器可对话 | 通过代理的 Claude 正常响应 | MANDATORY | 手动测试 |
| G-2.2 | 监控面板正常 | Grafana 指标正常显示 | MANDATORY | 查看面板 |
| G-2.3 | 熔断 Fallback 测试 | 手动停止代理后，Claude 自动切直连 | MANDATORY | 停止代理 → 检查 Claude 能否继续工作 |
| G-2.4 | Fallback 恢复测试 | 启动代理后，Claude 自动切回 | MANDATORY | 启动代理 → 检查 ANTHROPIC_BASE_URL |
| G-2.5 | 代理延迟 | P50 引入延迟 < 50ms, P99 < 200ms | MANDATORY | Grafana 面板 |
| G-2.6 | 错误率 | 代理不增加错误率（错误率 < 0.1%） | MANDATORY | Grafana 对比 |
| G-2.7 | CK 完整率 | CK 日志记录率 > 99%（允许 CK 短暂不可用） | TOLERANCE | CK 查询对比代理计数 |
| G-2.8 | 熔断自动恢复 | 模拟上游故障，熔断 OPEN → 恢复 → CLOSED | MANDATORY | Chaos 测试 |
| G-2.9 | Watch 进程自动 Fallback | 代理宕机后 Watch 自动切直连 | MANDATORY | 停止代理 → 检查 Watch 日志 |
| G-2.10 | 观察 1 小时 | 无异常，无告警 | MANDATORY | 手动监控（每 5 分钟检查） |
| G-2.11 | 观察 24 小时 | 无 crash，无 OOM，无异常 | MANDATORY | 持续监控 |
| G-2.12 | 峰值并发 | 支撑 50+ 并发请求 | TOLERANCE | 实际流量观察 |

**Phase 2 退出条件：G-2.1 ~ G-2.6 全部通过，G-2.8 ~ G-2.9 手动测试通过，观察 24 小时无问题。**

### 4.5 Phase 3：扩展所有 sandbox

**目标：全量上线，持续稳定运行。**

**前置条件：Phase 2 全部通过，且 24 小时观察期无问题。**

| Gate | 检查项 | 标准 | 类型 | 验证方式 |
|------|--------|------|------|----------|
| G-3.1 | 灰度扩展 | 逐个切换 sandbox，每个观察 10 分钟 | MANDATORY | 逐批切换脚本 |
| G-3.2 | 全量后代理负载 | 所有 sandbox 通过代理后，内存 < 192MB | MANDATORY | docker stats |
| G-3.3 | 全量后延迟 | P50 < 无代理 + 50ms, P99 < +200ms | MANDATORY | Grafana |
| G-3.4 | 全量后错误率 | 代理不增加错误率（error_rate < 0.5%） | MANDATORY | Grafana |
| G-3.5 | 观察 1 周 | 无 crash，无 OOM，无异常 | MANDATORY | 持续监控 |
| G-3.6 | 用户反馈收集 | 无异常抱怨 | TOLERANCE | 团队反馈 |
| G-3.7 | 自动恢复演练 | 模拟代理宕机，Watch 自动 Fallback 和恢复 | MANDATORY | 月度 Chaos 演练 |

**Phase 3 退出条件：G-3.1 ~ G-3.5 全部通过，稳定运行 1 周。**

### 4.6 熔断验收矩阵

| 场景 | 预期行为 | 验收方式 | 验收时间 |
|------|----------|----------|----------|
| 代理宕机 | Watch 进程在 12s 内切直连 | 手动 docker stop proxy | Phase 2 |
| 代理恢复正常 | Watch 进程在 30s 内切回 | 手动 docker start proxy | Phase 2 |
| DeepSeek 持续 5xx | 熔断器在 5m 窗口内 >20% 失败率时 OPEN | Integration 测试 | Phase 1 |
| DeepSeek 恢复 | HALF-OPEN 探测成功 → CLOSED | Integration 测试 | Phase 1 |
| CK 不可用 | 代理继续工作，CK 写入跳过 | Integration 测试 | Phase 1 |
| 网络延迟抖动 | 代理正常，熔断器不误触 | Chaos 测试 | Phase 1 |

### 4.7 性能验收矩阵

| 指标 | 目标值 | 测试条件 | 验收时间 |
|------|--------|----------|----------|
| 非 streaming 代理延迟（P50） | < 5ms | Mock `fast_path_non_stream`，100 次请求 | Phase 1 |
| 非 streaming 代理延迟（P99） | < 20ms | Mock `fast_path_non_stream`，100 次请求 | Phase 1 |
| Streaming TTFT（P50） | < 50ms | Mock `happy_path_stream`，50 次请求 | Phase 1 |
| Streaming TTFT（P99） | < 200ms | Mock `happy_path_stream`，50 次请求 | Phase 1 |
| 每 chunk Flush 延迟（P50） | < 1ms | Mock 100 chunks，interval 10ms | Phase 1 |
| 每 chunk Flush 延迟（P99） | < 5ms | Mock 100 chunks，interval 10ms | Phase 1 |
| 200 并发 | 全部成功 | Mock `fast_path_non_stream` | Phase 1 |
| 1000 req/s 吞吐 | 全部成功 | 1KB 响应，100 并发 | Phase 1 |
| 50 并发 streaming | 全部完成 | Mock，每个持续 30s | Phase 1 |
| 空载内存 | < 20MB | 启动后等待 10s | Phase 1 |
| 高峰期内存 | < 128MB | 200 并发 + 50 streaming | Phase 1 |
| 1 小时无内存泄漏 | RSS 无持续增长 | 持续请求 1 小时 | Phase 1 |

---

### 4.8 回滚策略

#### 4.8.1 硬性触发条件

出现以下任一条件，**自动触发回滚**（无需人工确认）：

| 编号 | 条件 | 检测方式 | 触发时间 |
|------|------|----------|----------|
| R-01 | Phase 1/2 范围内 P99 延迟 > 无代理 + 500ms 持续 5 分钟 | Grafana 告警 | 自动 |
| R-02 | 代理错误率 > 5% 持续 3 分钟（429 除外） | Grafana 告警 | 自动 |
| R-03 | 代理进程 crash 或 OOM | systemd/docker 自动重启检测 | 自动 |
| R-04 | CK buffer 使用率 > 80% 持续 30 秒 | 代理自身 metric（buffer_usage_ratio） | 自动 |
| R-05 | 熔断器 OPEN 状态持续超过 5 分钟 | /readiness + 告警 | 自动 |
| R-06 | Watch 进程连续 5 次以上 fallback 到直连 | Watch 日志监控 | 自动 |
| R-07 | 人工发现异常（如 PII 泄漏、错误转发） | 人工报告 | 人工确认后触发 |

#### 4.8.2 分阶段回滚步骤

```
Phase 1 回滚（单个 sandbox）:
  步骤 1: 将该 sandbox 的 ANTHROPIC_BASE_URL 切回直连
  步骤 2: Watch 检测到代理不再使用，停止健康检查
  步骤 3: 保留代理容器运行，持续观察日志
  步骤 4: 根因分析完成前不复用

Phase 2 回滚（boss 容器）:
  步骤 1: 将 boss 容器切回直连（ANTHROPIC_BASE_URL 指向 api.deepseek.com）
  步骤 2: Watch 自动 fallback 确认
  步骤 3: 灰度中其它容器保持代理不变（如有）
  步骤 4: 通知全组 "代理异常，boss 已切直连"
  步骤 5: 停止代理容器（docker stop proxy），保留 CK 数据

Phase 3 回滚（全量）:
  步骤 1: 批量脚本将所有 sandbox ANTHROPIC_BASE_URL 切回直连
  步骤 2: 停止 Watch 进程（避免反复切换）
  步骤 3: 停止代理容器
  步骤 4: 通知全员 "代理已下线"
  步骤 5: 保留 CK 数据和日志，用于后期根因分析
```

#### 4.8.3 决策 RACI

| 决策 | 自动/人工 | 责任人 | 响应时间 |
|------|-----------|--------|----------|
| R-01~R-06 触发回滚 | **自动**，无需确认 | Watch / 告警系统 | < 30s |
| R-07 人工触发回滚 | **人工** | 值班 SRE / 发现者 | 立即 |
| 回滚后根因分析 | **人工** | 代理负责人 | 1 小时内 |
| 回滚后重新上线 | **人工** | 代理负责人 + 审查 | 根因修复后 |
| 灰度范围调整（缩容） | **人工** | 值班 SRE | 15 分钟内 |
| 灰度暂停（扩容停止） | **自动**（任何 Red 告警） | 告警系统 | 立即 |

---

## 5. 附录

### A. 失败模式速查表

当某个测试失败时，按以下顺序排查：

```
TC 失败
  │
  ├── 1. Mock Server 是否就绪？         → check /__admin/health
  ├── 2. 代理是否就绪？                  → check /healthz
  ├── 3. CK 是否就绪？                   → check CK port
  ├── 4. Mock 场景是否设置正确？         → check /__admin/scenario
  ├── 5. Request 是否正确到达 Mock？     → check /__admin/requests
  ├── 6. 代理日志中有无异常？            → docker logs proxy
  ├── 7. 超时配置是否符合预期？          → check CONNECT/IDLE/TOTAL_TIMEOUT
  └── 8. 检查 docker-compose 网络        → docker network inspect
```

### B. 测试数据生成

测试中使用的 mock 数据：

- **API key**: `sk-test-key-001` / `sk-test-key-002` / `sk-test-key-003`（用于多个 API key 测试）
- **Request ID**: 自动生成 UUID（验证唯一性）
- **Trace ID**: `trace-` + UUID（用于跨系统追踪）
- **模型名**: `deepseek-chat` / `deepseek-reasoner`（reasoning 模型测试）
- **客户端 IP**: `172.16.0.1` / `172.16.0.2`（Docker 内部 IP）

### C. 时间参数速查

| 参数 | 默认值 | 测试中使用的值 | 说明 |
|------|--------|---------------|------|
| CONNECT_TIMEOUT | 10s | 3s（加速测试） | TCP 连接超时 |
| IDLE_TIMEOUT | 60s | 10s（加速测试） | Streaming 空闲超时 |
| TOTAL_TIMEOUT（非 streaming） | 30s | 5s（加速测试） | 非 streaming 总超时 |
| TOTAL_TIMEOUT（streaming） | 300s | 30s（加速测试） | Streaming 总超时 |
| CB_WINDOW_SIZE | 5m | 30s（加速测试） | 熔断滑动窗口 |
| CB_HALF_OPEN_TIMEOUT | 30s | 10s（加速测试） | 半开等待时间 |
| health_check_interval | 10s | 1s（加速测试） | 内部巡检间隔 |

**测试中超时参数可缩短以加速运行，但要确保覆盖率等价。Integration 测试使用加速参数，性能测试使用生产参数。**

### D. 测试完成检查清单

```
[ ] Unit 测试全部通过，覆盖率 > 80%
[ ] Integration 测试全部通过（所有 TC）
[ ] Chaos 测试全部通过（所有场景）
[ ] E2E 手动测试通过（dry-run）
[ ] 性能基准全部达标
[ ] 熔断器功能验证通过
[ ] CK fail-open 验证通过
[ ] Fallback 自动恢复验证通过
[ ] 错误格式转换验证通过
[ ] PII 脱敏验证通过
[ ] SSRF 白名单验证通过
[ ] 优雅关闭验证通过
[ ] 速率限制验证通过
[ ] Phase 0 ~ 3 全部 Gate 通过
```

---

> **本文件由 boss 设计，Claude Code (DeepSeek) 编写，10 人审查通过后进入 Phase 1 实现阶段。**
>
> ／人◕ ‿‿ ◕人＼
