---
decision: 稍后做
---

# Review D2: MCP 全流程可观测性 -- Transport Config

Review of `docs/infra/designs/mcp-observability.md`.

## Summary

The design covers observability metrics and alerting well, but the transport layer --
the critical path between Claude Code and MCP Server -- is underspecified. Multiple
config gaps need resolution before proceeding to implementation.

## Findings

### 1. Transport selection is unresolved

The document lists `stdio/HTTP-SSE` as a choice but provides no criteria for when to
use which. These transports have fundamentally different operational properties:

- **stdio**: Claude Code launches the MCP Server as a child process. No network,
  no TLS, lowest latency. Suitable for local-only, single-user scenarios. However,
  the container's process lifecycle must match Claude Code's -- if the MCP Server
  exits, the transport dies too. The `mcp_server_up` gauge cannot meaningfully
  distinguish between "server crashed" and "Claude Code closed the pipe."

- **HTTP-SSE**: Server runs independently; Claude Code connects via HTTP. Enables
  server-side observability regardless of client state. But introduces network
  latency, TLS termination, and connection management. SSE connections are
  long-lived and count against container connection limits.

**Recommendation**: Make the choice explicit. If both are supported, document the
decision matrix and configure via `.mcp.json` transport field.

### 2. No `.mcp.json` transport configuration example

Step 2 of the implementation plan ("配置 .mcp.json") is a placeholder. The file
must specify:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "docker",
      "args": ["run", "--rm", "-i", "mcp-server-image"],
      "env": {}
    }
  }
}
```

For HTTP-SSE the config schema differs:

```json
{
  "mcpServers": {
    "my-server": {
      "url": "https://mcp.internal:8443/sse",
      "headers": {}
    }
  }
}
```

Missing details:
- How does the Docker container image get deployed for each transport mode?
- For stdio: is the container expected to be running already, or does Claude Code
  launch it each time? If launch-on-demand, exit behavior matters (see finding 1).
- For HTTP-SSE: what URL does the client use? Is it behind Tailscale? An internal
  load balancer?

### 3. TLS and authentication

HTTP-SSE transport over plaintext is unacceptable for production. The document
mentions no TLS config, no mTLS, and no token-based auth. The transport layer
must specify:

- TLS termination point (reverse proxy or MCP Server itself)
- Certificate management (auto-rotation via Tailscale? Let's Encrypt?)
- Client authentication (API token in `headers` field? mTLS?)
- Whether HTTP-SSE listeners are bound to localhost only (safe for stdio-only
  deployments) or exposed on a network interface

### 4. No transport-level timeout configuration

The document defines MCP-level timeout metrics (`mcp_request_duration_ms`) and
alerts (P99 > 10s for 5 min), but transport timeouts can fire before MCP-level
timeout logic kicks in:

- HTTP connection timeout
- SSE stream reconnect timeout
- stdio process spawn timeout

If the transport layer has a 5s default timeout but MCP-level alerting expects
10s, you get false-positive P2 alerts. Align timeout values between MCP and
transport layers, or document the interaction explicitly.

### 5. `mcp_server_up` gauge semantics

The `mcp_server_up` gauge (0/1) is ambiguous without transport context:

- **stdio**: gauge reflects whether the child process is alive. Worthless if the
  server is designed to exit after idle (some servers exit after N minutes).
- **HTTP-SSE**: gauge reflects whether the HTTP endpoint responds. A 200 status
  from a health endpoint is more useful than connection-state tracking.

**Recommendation**: Replace with a transport-aware health probe. For HTTP-SSE,
use `/healthz` endpoint response. For stdio, use a periodic `ping`/`pong` MCP
message round-trip instead of process-liveness.

### 6. Retry layering confusion

Claude Code's built-in exponential backoff (finding 2 in the doc, "自愈") operates
at the MCP protocol layer. But the transport layer may also retry:

- HTTP-SSE clients often have their own connection-level retry (e.g., `keepalive`
  agent, axios retry).
- stdio shells may restart the process on exit (e.g., systemd unit Restart=).

If both layers retry independently, you get multiplicative retries. A transient
failure could trigger MCP-level retry *and* transport-level reconnect, doubling
the request count and skewing `mcp_requests_total` counters.

**Recommendation**: Disable transport-level retry and rely solely on Claude Code's
MCP-level backoff. Document this explicitly in the configuration.

### 7. No transport-level metrics

The five metrics defined (`mcp_requests_total`, `mcp_request_duration_ms`,
`mcp_errors_total`, `mcp_retries_total`, `mcp_server_up`) are all MCP-protocol-level.
Missing transport-level signals:

- `mcp_transport_reconnects_total` -- counter of transport reconnections
- `mcp_transport_bytes_sent/received` -- wire-level throughput
- `mcp_transport_connect_duration_ms` -- time to establish transport connection

Without these, you cannot distinguish "the MCP Server returned an error" from
"the transport dropped the connection before the request reached the server."

## Overall

The observability design is sound for MCP protocol-level monitoring but the
transport layer needs a dedicated design pass before implementation begins.
The gaps identified would lead to false alerts, ambiguous metrics, and potential
double-retry issues in production. Recommend a follow-up D3 that resolves
findings 1-7 with concrete `.mcp.json` configs and transport-metric additions.

/人◕ ‿‿ ◕人＼
