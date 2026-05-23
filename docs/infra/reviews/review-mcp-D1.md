---
decision: 稍后做
---

# Review D1: MCP Observability Design

**Review of:** `docs/infra/designs/mcp-observability.md`
**Date:** 2026-05-23
**Reviewer:** boss

## MCP Server Status

**Current state: Zero MCP servers running.** The document itself states this clearly ("当前环境无 MCP Server 运行"). This means:

- There is no active Claude-MCP integration to observe yet.
- All metrics defined (`mcp_requests_total`, `mcp_request_duration_ms`, `mcp_errors_total`, `mcp_retries_total`, `mcp_server_up`) will produce zero values until at least one MCP server is deployed.
- The `mcp_server_up` gauge (0/1) is trivially 0 across all environments.

## Design Assessment

The document is a lightweight forward-looking sketch ("此方案为后续引入做准备"). It covers the fundamentals:

- **Architecture**: Claude Code -> MCP Transport -> MCP Server container -- standard, correct.
- **Collection points**: call start/completion/error/reconnect -- sufficient coverage.
- **Metrics**: standard RED (Rate/Errors/Duration) pattern with retries and up/down gauge. Sensible.
- **Alerts**: P0/P1/P2 severity mapping with concrete thresholds. Good to define early.
- **Self-healing**: acknowledged (exponential backoff + built-in tool fallback).

## Gaps

1. **No specific MCP server types defined** -- what servers will run? (filesystem, fetch, DB, custom?) Each has different failure modes and latency profiles.
2. **No transport security documented** -- stdio vs HTTP-SSE carries different observability needs (HTTP-SSE can be scraped externally; stdio requires stdout parsing).
3. **No auth/credential model** -- if MCP servers need tokens or DB creds, where do they come from?
4. **No .mcp.json example** -- the config file that wires servers into Claude Code should be included.
5. **No deployment detail** -- container image, port mapping, restart policy, resource limits.
6. **No Vector config** -- how logs flow from MCP containers to ClickHouse is referenced but not sketched.

## Verdict

**Accept as forward-looking design.** The metrics schema and alert thresholds are well-chosen and will not need rework when implementation starts. Defer closing the gaps above to implementation phase (step 1: "部署 MCP Server 容器"), at which point concrete server types and transport choices will force these decisions naturally.
