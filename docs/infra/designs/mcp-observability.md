---
decision: 稍微有点不确定等专家再审一轮
---

# MCP 全流程可观测性

MCP（Model Context Protocol）是 Claude Code 官方工具协议。当前环境无 MCP Server 运行，此方案为后续引入做准备。

## 架构
Claude Code ←→ MCP Transport (stdio/HTTP-SSE) ←→ MCP Server 容器

## 采集点
1. MCP 调用开始（tool, server, params size）
2. 调用完成（status, latency, output size）
3. 错误（timeout, rejected, disconnect, protocol_error）
4. 重连事件（retry count, backoff）

## 指标体系
- mcp_requests_total (counter, tool/server/status)
- mcp_request_duration_ms (histogram, P50/P90/P99)
- mcp_errors_total (counter, error_type)
- mcp_retries_total (counter, tool/server)
- mcp_server_up (gauge, 0/1)

## 告警
- 连续 3 次错误且无 success → P1
- P99 > 10s 持续 5min → P2
- server_down > 30s → P0

## 自愈
Claude Code 内置指数退避重连（1s→2s→4s→8s→60s max）。5 次失败 fallback 到内置工具。

## 实施路线
1. 部署 MCP Server 容器
2. 配置 .mcp.json
3. 验证调用链路
4. 部署打点采集（Vector → CK）
5. 配置告警
