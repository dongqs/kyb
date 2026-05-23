# Network-level Claude Traffic Capture

> 2026-05-22 — Infra analysis for capturing all Claude API traffic into ClickHouse

## Current Traffic Flow

### Discovery: Claude Uses DeepSeek, Not Anthropic

Before designing capture, the most important finding:

```
ANTHROPIC_BASE_URL = https://api.deepseek.com/anthropic
ANTHROPIC_MODEL   = deepseek-v4-flash[1m]
```

Claude Code is configured to talk to DeepSeek's API (which speaks the Anthropic Messages API format on a custom path). All traffic goes to:

```
api.deepseek.com → 117.185.125.154 / 183.192.184.85 (Chinese IPs)
```

### Complete Traffic Path

```
Claude Code (in kyb container)
  │ ALL_PROXY=socks5://kyb-infra-sing-box:2080
  ▼
kyb-infra-sing-box (192.168.97.2)
  │ mixed inbound on 0.0.0.0:2080 (SOCKS5+HTTP)
  │ DNS via 119.29.29.29 → api.deepseek.com → Chinese IPs
  │ Rule matching (evaluated top-down):
  │   Rule  0-7: .local / private IPs / DNS hijack / ads → no match
  │   Rule  9: ai-extra (anthropic.com, claude.ai, ...) → no match (DeepSeek not in list)
  │   Rule 10: ai-sites (category-ai-!cn) → no match (DeepSeek is Chinese AI, excluded by !cn)
  │   Rule 16: cn-ip (Chinese IP geoip) → MATCH ✓
  ▼
direct outbound → Chinese DeepSeek servers
```

**Key insight**: DeepSeek traffic goes **direct** (not through any relay), because DeepSeek servers have Chinese IPs and match the `cn-ip` rule_set at position 16.

If cn-ip geoip database misses these IPs, the default route is `Relay-JP2` (Japanese shadowsocks relay).

### What Flows Through the Proxy

| Traffic | Route | Notes |
|---------|-------|-------|
| api.deepseek.com (Claude/DeepSeek) | cn-ip → **direct** | Primary target for capture |
| api.anthropic.com | ai-extra → Relay-US2 | If someone uses raw Anthropic |
| claude.ai / anthropic.com | ai-extra → Relay-US2 | Web UI traffic |
| cursor.sh / cursor.com | Rule 8 → Cursor-Auto | Separate traffic |
| git.leyantech.com | Rule 15 → nuc8-proxy | GitLab via nuc8 socks proxy |
| All other non-CN | default → **Relay-JP2** | Shadowsocks relay |

### Agent_events Table Already Exists

ClickHouse `kyb.agent_events` already exists with schema:

```sql
CREATE TABLE kyb.agent_events (
  `timestamp`        DateTime,
  `agent_id`         String,
  `session_id`       String,
  `task_id`          String,
  `project`          String,
  `event_type`       String,
  `content`          String,
  `parent_agent_id`  String,
  `tags`             Map(String, String)
) ENGINE = MergeTree ORDER BY (project, timestamp)
```

This is populated by agent-side explicit reporting (not network capture).

---

## Approaches Ranked

### Approach A: Sing-box Access Logging (Feasibility: 5/5)

**Effort: Low | Value: Medium | Disruption: None**

Enable sing-box's built-in connection logging to capture per-connection metadata.

```
Current log: {"level": "info", "timestamp": true}
No access log enabled, no disabled output path.
```

What we get:
- Timestamp, src/dst IP:port, protocol, bytes transferred
- Which outbound was used (direct, relay, etc.)
- Connection duration
- Per-connection metadata only

What we DON'T get:
- Request/response content (encrypted TLS)
- Token counts, model names, prompt/response text
- Agent identity (src IP is the kyb container's Docker IP, not the agent name)

**Implementation**:
1. Enable `access` logging in sing-box config.json
2. Mount a log volume or pipe to a log shipper
3. Parse with Filebeat or a custom tailer into ClickHouse

**Requires**: Sing-box config edit + restart. No changes to Claude containers.

**Volume**: ~50-200 lines/second during active Claude use. Trivially ingestible.

---

### Approach B: MITM Proxy Container (Feasibility: 3/5)

**Effort: High | Value: Very High | Disruption: Medium**

Insert a MITM proxy between Claude and sing-box:

```
Claude Code → MITM Proxy (port 2080) → sing-box (port 2081) → internet
```

**Implementation options**:

a) **mitmproxy** — Full-featured, Python-based. Can record flows and stream to ClickHouse via webhook.
   - Docker image available: `mitmproxy/mitmproxy`
   - Needs TLS certs installed in Claude containers
   - Can run transparent or as explicit proxy
   - Flow streaming API for real-time export

b) **Custom Go proxy** — Lightweight, only captures what we need
   - Accept SOCKS5, forward to sing-box
   - Sniff HTTP CONNECT destination
   - Parse Anthropic/DeepSeek API payloads
   - ~200 lines of Go, no dependencies
   - Faster and more targeted than mitmproxy

**TLS Certificate Problem** (the hard part):
- MITM must decrypt HTTPS to see content
- Claude Code must trust the MITM CA certificate
- Options:
  1. Set `NODE_EXTRA_CA_CERTS` in Claude container env
  2. Mount cert into container's trust store via Dockerfile
  3. Set `ANTHROPIC_BASE_URL=http://...` (no TLS, but DeepSeek may reject)
  4. Use environment variable to disable cert verification (`NODE_TLS_REJECT_UNAUTHORIZED=0`)
- If we control the kyb container Dockerfile and entrypoint, options 1-2 are feasible

**What we get**:
- Full request payloads (system prompt, messages, tools)
- Full response payloads (content blocks, stop reason)
- Token usage (`usage.input_tokens`, `usage.output_tokens`)
- Model name, request ID, latency per request
- SSE stream timing (time-to-first-token, inter-token latency)
- Agent identity (if we can map src IP to container name / worktree)

**Anthropic/DeepSeek API shape** (Messages API):
```
POST /anthropic/messages
Headers: x-api-key, anthropic-version, content-type
Body: {
  "model": "deepseek-v4-flash[1m]",
  "messages": [{"role": "user", "content": "..."}],
  "system": "...",
  "max_tokens": 4096,
  "stream": true   ← SSE streaming
}
Response (streaming): SSE events with delta content blocks + message_stop
Response (non-streaming): {
  "content": [...],
  "usage": {"input_tokens": 123, "output_tokens": 456},
  "model": "..."
}
```

**Requires**:
- New container or process on kyb-net
- TLS cert management
- Either Dockerfile change or runtime env config
- Proxy chain reconfiguration (change ALL_PROXY target)

---

### Approach C: Docker Network Capture (Feasibility: 2/5)

**Effort: Medium | Value: Low | Disruption: Low**

Use `tcpdump` on the kyb-net Docker bridge or from a container with `NET_ADMIN`.

```
docker run --rm --network kyb-net --cap-add NET_ADMIN \
  -v /tmp/capture:/capture nicolaka/netshoot \
  tcpdump -i eth0 -w /capture/claude.pcap
```

**Problems**:
- Traffic is **TLS-encrypted** — pcap shows IPs, ports, timing, and byte counts but no content
- Without MITM decryption, pcap provides same data as sing-box access log but with more effort
- High volume — 10-100MB/hour for a busy session
- Hard to parse in real-time — pcap processing is batch-oriented
- Need to map src IPs to agent identities (Docker DNS names help)

**Use case**: Network troubleshooting, latency analysis, connection counts. Not useful for content capture.

---

### Approach D: Sing-box Custom Outbound with Logging (Feasibility: 4/5)

**Effort: Medium | Value: Medium | Disruption: Low**

Use sing-box's existing features to tee/capture traffic without MITM.

Options:

a) **Clash API** — Sing-box is compiled `with_clash_api` but not configured.
   - Enable the Clash REST API for connection stats
   - Provides real-time connection list with: metadata (host, port, type), upload/download bytes, start time, rule, outbound
   - Pollable via HTTP `/connections` endpoint
   - No payload content, but richer than basic logs

b) **Custom routing** — Route AI traffic through a specific outbound that logs:
   - Add a new rule for `api.deepseek.com` → tag it to a dedicated outbound
   - The outbound can be `direct` with a logging wrapper
   - Sing-box doesn't natively log per-outbound, but we can write a process that tail logs

c) **DNS logging** — Enable sing-box DNS query logging to capture which domains Claude resolves:
   - Every `api.deepseek.com` resolution is logged
   - Can infer request volume from DNS query frequency

**Implementation**: Enable clash_api in sing-box config, poll `/connections` endpoint, feed to ClickHouse.

```json
{
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "external_ui": "",
      "secret": "",
      "default_mode": "rule"
    }
  }
}
```

---

### Approach E: iptables/NFTABLES + NFLOG (Feasibility: 3/5)

**Effort: Medium | Value: Low | Disruption: Low**

```
nft add rule inet filter mangle ip daddr 183.192.184.85 log prefix "CLAUDE: "
```

**Problems**:
- Same TLS limitation as pcap — metadata only
- Requires nftables, which is available on the Orbstack host
- Doesn't capture domain names (only IPs after DNS resolution)
- Hard to correlate with agent identity
- Kernel logging is slow and not designed for high-volume capture

**Not recommended** — sing-box access logging is strictly better (it knows domain names from the SOCKS5 CONNECT handshake).

---

### Approach F: SSE Stream Capture (Feasibility: 4/5 with MITM, 1/5 without)

SSE (Server-Sent Events) is used by both Anthropic and DeepSeek for streaming responses. The stream format is:

```
event: content_block_delta
data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "..."}}

event: content_block_stop
data: {"index": 0}

event: message_delta
data: {"delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 456}}

event: message_stop
data: {}
```

**Without MITM**: SSE is inside TLS — cannot see stream events.

**With MITM**: Can capture per-event timing (time-to-first-token, inter-token latency, tokens/second) for performance analysis.

**Use case**: Performance dashboards when MITM is in place.

---

## Recommended Approach: Three-Phase Strategy

### 砍需求原则 (80/20)

What actually provides value for infra-boss operations:

| Need | Value | Capture method |
|------|-------|----------------|
| Which agents are running? | High | agent_events (existing) |
| How many API calls per session? | High | Sing-box access log |
| How much time in API vs thinking? | High | Sing-box access log + timing |
| Token usage per session? | Medium | MITM or DeepSeek API response |
| What prompts are being sent? | Low-Medium | MITM (privacy concern) |
| Subagent hierarchy + API traffic correlation? | High | agent_events + access log + src IP mapping |
| Real-time resource allocation decisions? | High | Sing-box clash API |
| Performance degradation detection? | Medium | Connection timing from access log |

### Phase 1: Sing-box Access Log + Clash API (Effort: 1 day)

**Goal**: Get connection-level metadata into ClickHouse immediately.

**Implementation steps**:

1. **Enable Clash API** in sing-box config:
   ```json
   {
     "experimental": {
       "clash_api": {
         "external_controller": "0.0.0.0:9090",
         "secret": "kyb-infra-token"
       }
     }
   }
   ```

2. **Add explicit DeepSeek routing rule** (before cn-ip) to ensure we can identify Claude traffic:
   ```json
   {
     "domain": ["api.deepseek.com"],
     "outbound": "direct",
     "rule_set": []
   }
   ```

3. **Deploy a tiny poller** (Docker container on kyb-net) that:
   - Polls Clash API `/connections` every 2s
   - Inserts connection snapshots into ClickHouse:
     ```sql
     INSERT INTO kyb.network_connections
     (timestamp, src_ip, dst_host, dst_port, upload_bytes, download_bytes,
      start_time, outbound_rule, agent_container, protocol)
     VALUES (...)
     ```
   - Maps src_ip to container name via Docker API
   - Maps container name to agent session via agent_events

4. **Schema for access log data**:
   ```sql
   CREATE TABLE kyb.network_connections (
     timestamp       DateTime,
     src_ip          String,       -- Docker container IP (192.168.97.x)
     src_container   String,       -- Resolved container name
     dst_host        String,       -- Domain name (from SOCKS5 handshake)
     dst_ip          String,       -- Resolved IP
     dst_port        UInt16,
     protocol        String,       -- TCP / UDP
     outbound_rule   String,       -- direct, Relay-JP2, etc.
     start_time      DateTime,
     end_time        Nullable(DateTime),
     upload_bytes    UInt64,       -- Total bytes sent
     download_bytes  UInt64,       -- Total bytes received
     agent_id        Nullable(String),  -- Correlated from agent_events
     session_id      Nullable(String),  -- Correlated from agent_events
     project         Nullable(String),
     tags            Map(String, String)
   ) ENGINE = MergeTree
     ORDER BY (project, timestamp)
     SETTINGS index_granularity = 8192
   ```

**Ingestion pipeline**:
```
sing-box (access log / clash API)
  → poller container (Ruby or Go, on kyb-net)
  → ClickHouse kyb.network_connections
  → JOIN agent_events on timestamp window + container IP
```

### Phase 2: API Payload Extraction via Request Mirroring (Effort: 2-3 days)

**Goal**: Capture HTTP request/response metadata (not full content) from the DeepSeek API.

Instead of full MITM, use a **lighter approach**: deploy a sidecar proxy on the kyb-net that sits alongside sing-box and receives a copy of traffic destined for `api.deepseek.com`.

This is actually feasible with **eBPF** or **NFQUEUE** to intercept and mirror traffic, but those require kernel modules not available in all Docker environments.

**Pragmatic alternative**: Modify the `direct` outbound for DeepSeek to route through an intermediate **transparent TCP proxy** that:
- Receives raw TCP from sing-box
- Forwards to DeepSeek (direct)
- Records connection start/end, total bytes, TLS SNI
- Optionally: implements "poor man's MITM" by reading TLS SNI and certificate metadata only

This gives us slightly more than Phase 1 (SNI confirmation, TLS handshake timing) but still no content.

### Phase 3: MITM Proxy (Effort: 3-5 days) — Optional

**Goal**: Full request/response payload capture including token usage.

**Implementation steps**:

1. **Deploy mitmproxy container** on kyb-net:
   ```bash
   docker run -d --name kyb-infra-mitm \
     --network kyb-net \
     -v /home/dev/kyb/mitm/data:/home/mitmproxy/.mitmproxy \
     mitmproxy/mitmproxy \
     mitmdump --mode socks5 --listen-port 2080 \
              --set upstream=socks5://kyb-infra-sing-box:2081
   ```

2. **Reconfigure proxy chain**:
   - Change sing-box port 2080 to 2081 (MITM backend)
   - Point ALL_PROXY to `kyb-infra-mitm:2080`
   - OR: change sing-box config to route DeepSeek through MITM

3. **Install MITM CA cert in all Claude containers**:
   - Option A: Add to Dockerfile base image (`/usr/local/share/ca-certificates/`)
   - Option B: Mount at container start via `-v`
   - Option C: Set `NODE_EXTRA_CA_CERTS` env var
   - Option D: For Node.js Claude, `NODE_TLS_REJECT_UNAUTHORIZED=0` (not recommended for security)

4. **Add ClickHouse streaming**:
   - mitmproxy can export flows to Python scripts via `mitmdump -s capture_to_ck.py`
   - The inline script parses DeepSeek API requests/responses and inserts into ClickHouse

5. **Schema for API request/response data**:
   ```sql
   CREATE TABLE kyb.api_requests (
     timestamp       DateTime,
     agent_id        Nullable(String),
     session_id      Nullable(String),
     request_id      String,           -- From API response
     model           String,           -- deepseek-v4-flash, etc.
     endpoint        String,           -- /anthropic/messages, etc.
     method          String,           -- POST
     stream          Boolean,          -- Whether SSE streaming was used
     request_size    UInt32,           -- Request body bytes
     request_messages UInt16,          -- Number of messages in request
     request_tokens  Nullable(UInt32), -- input_tokens from response usage
     response_size   UInt32,           -- Response body bytes
     response_tokens Nullable(UInt32), -- output_tokens from response usage
     latency_ms      UInt32,           -- Total request-response time
     ttft_ms         Nullable(UInt32), -- Time to first token (streaming)
     status_code     UInt16,           -- HTTP status
     error           Nullable(String),
     project         Nullable(String),
     tags            Map(String, String)
   ) ENGINE = MergeTree
     ORDER BY (project, timestamp)
     SETTINGS index_granularity = 8192
   ```

---

## Phase 1 Detailed Implementation

### Step 1: Enable Clash API in Sing-box

Edit `/etc/sing-box/config.json` on `kyb-infra-sing-box`:

```json
{
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "external_ui": "",
      "secret": "kyb-infra-token"
    }
  }
}
```

Restart: `docker restart kyb-infra-sing-box`

### Step 2: Poller Container

Deploy a small Ruby (or Go) container on kyb-net:

```
kyb-net┌─────────────────────────────────────────────┐
        │  kyb-infra-capture (poller)               │
        │  ┌──────────┐  ┌──────────────────────┐   │
        │  │ Clash    │  │ Docker API poller    │   │
        │  │ consumer │──│ (container→IP mapping)│   │
        │  └────┬─────┘  └──────────┬───────────┘   │
        │       │                   │                │
        │       ▼                   ▼                │
        │  ┌─────────────────────────────────────┐   │
        │  │ ClickHouse Inserter                 │   │
        │  └──────────────────┬──────────────────┘   │
        └─────────────────────┼──────────────────────┘
                              │ HTTP (8123)
                              ▼
                     host.orb.internal:8123
```

Pseudo-code for poller:

```ruby
# kyb-infra-capture main loop
loop do
  # 1. Get connections from Clash API
  connections = http_get("http://kyb-infra-sing-box:9090/connections?secret=kyb-infra-token")
  
  # 2. Get container IP mapping from Docker
  containers = docker_ps_with_networks
  
  # 3. For each connection, find the source container
  connections.each do |conn|
    src_container = containers[conn.metadata.source_ip]
    agent = agent_events_lookup(src_container, time_window: 5.minutes)
    
    # 4. Insert into ClickHouse
    clickhouse_insert("kyb.network_connections", {
      timestamp: Time.now,
      src_ip: conn.metadata.source_ip,
      src_container: src_container,
      dst_host: conn.metadata.host,
      dst_port: conn.metadata.port,
      upload_bytes: conn.upload,
      download_bytes: conn.download,
      start_time: conn.start_time,
      agent_id: agent&.agent_id,
      session_id: agent&.session_id,
      project: agent&.project
    })
  end
  
  sleep 2
end
```

### Step 3: Container Name to Agent ID Mapping

The Docker API gives us container names like `kyb-fix-bug-abc123`. The agent_events table has `agent_id` fields. Correlation options:

a) **Explicit tagging**: Set container labels with agent metadata at create time:
   ```bash
   kyb exec <name> -- ...  # kyb stores: container_name ↔ agent_id mapping
   ```

b) **Heuristic**: Parse container name to extract agent/project info
   - kyb creates containers named `kyb-<project>-<branch>` for boss
   - Subagent containers use patterns like `kyb-agent-<name>-<id>`

c) **Timerange join**: Match connections from a container IP with agent_events within the same time window

Option (a) is the most reliable — add container labels when creating sandboxes.

### Step 4: Connect to agent_events

The network_connections table should be JOINable with agent_events on:

```
network_connections.agent_id = agent_events.agent_id
network_connections.session_id = agent_events.session_id
```

This gives us queries like:

```sql
-- How many API calls did each agent make?
SELECT
  ae.agent_id,
  ae.session_id,
  ae.parent_agent_id,
  count() as api_calls,
  sum(nc.download_bytes) as total_download,
  sum(nc.upload_bytes) as total_upload,
  max(nc.end_time) - min(nc.start_time) as session_duration
FROM kyb.agent_events ae
LEFT JOIN kyb.network_connections nc
  ON ae.agent_id = nc.agent_id
  AND ae.session_id = nc.session_id
GROUP BY ae.agent_id, ae.session_id, ae.parent_agent_id
ORDER BY api_calls DESC
```

---

## Estimated Data Volume

### Phase 1 (Connection Metadata)

| Metric | Value |
|--------|-------|
| Connections per Claude request | 2-5 (DNS + API + CDN) |
| Requests per agent session | 10-100 |
| Active agents at peak | 3-10 |
| Rows per hour (peak) | ~3,000-15,000 |
| Rows per day (24h) | ~50,000-200,000 |
| Storage per row | ~200 bytes |
| Storage per day | ~10-40 MB |
| Storage per year | ~4-15 GB |

### Phase 3 (Full API Capture, if enabled)

| Metric | Value |
|--------|-------|
| Rows per API request | 1 |
| Avg request+response size | 5-50 KB (prompts can be large) |
| Rows per hour (peak) | ~500-2,000 |
| Storage per day (data only) | ~50-500 MB |

Storage estimates are trivially low for ClickHouse. Neither phase requires any scaling consideration.

---

## Privacy / Security Considerations

### What We're Capturing

- **Phase 1**: IP addresses, domain names, connection timing, byte counts. Equivalent to what an ISP sees.
- **Phase 3**: Full API request/response bodies including prompts, code, and system instructions.

### Risks

1. **API keys in transit**: The `x-api-key` header passes through sing-box/MITM. If we capture headers, we capture the DeepSeek API key. **Mitigation**: Strip `x-api-key` from captured data; only store anonymized hash for correlation.
2. **Sensitive code in prompts**: Developers paste proprietary code into Claude. Full MITM capture means this data flows through our infrastructure. **Mitigation**: Phase 3 requires explicit opt-in. Phase 1 does not capture content.
3. **Subagent isolation**: Boss mode creates subagents for different projects. Network capture reveals which project each agent works on (via src container IP). **Mitigation**: Container names already encode this information; network capture doesn't materially change the threat model.
4. **SSE stream content in logs**: If sing-box access logging captures packet payloads (it doesn't — only metadata), SSE content could leak through info-level logs. **Mitigation**: Verify sing-box access log only captures metadata.

### Recommended Safeguards

- Phase 1: No content captured. Only metadata (IP, domain, bytes, timing). Safe for default-on.
- Phase 2 (request mirroring): Still only TCP-level. No TLS decryption. Safe for default-on.
- Phase 3 (MITM): Must be explicit opt-in. Requires:
  - Warning banner before enabling
  - Data retention limit (e.g., 7 days auto-purge)
  - `x-api-key` stripped before storage
  - Per-project opt-out mechanism
- All phases: Data stored in ClickHouse with the same access controls as existing kyb data.

---

## Integration with Existing Infrastructure

### kyb.reporter

The existing `Kyb::Reporter` module already emits lifecycle events to ClickHouse via HTTP API:

| Event | Data | Source |
|-------|------|--------|
| `kyb_build_duration` | Build timing | kyb build |
| `kyb_create_count` | Container creates | kyb create |
| `kyb_container_count` | Active containers | kyb ps |
| `preflight` | Network checks | kyb preflight |
| `proxy_status` | Proxy reachability | kyb preflight |
| `heartbeat` | System health | Cron |

These are application-level events that complement network capture. Network capture fills the gap: "what happened between create and destroy?"

The current reporter inserts to `kyb.metrics` and `kyb.sessions` tables (which don't exist yet in ClickHouse). There's also the `kyb.agent_events` table which was created separately.

### Recommended Schema Evolution

```sql
-- Phase 1: Create network_connections table
CREATE TABLE kyb.network_connections (
  timestamp       DateTime,
  src_ip          String,
  src_container   String,
  dst_host        String,
  dst_ip          String,
  dst_port        UInt16,
  protocol        String,
  outbound_rule   String,
  start_time      DateTime,
  end_time        Nullable(DateTime),
  upload_bytes    UInt64,
  download_bytes  UInt64,
  agent_id        Nullable(String),
  session_id      Nullable(String),
  project         Nullable(String),
  tags            Map(String, String)
) ENGINE = MergeTree
  ORDER BY (project, timestamp)
  SETTINGS index_granularity = 8192;

-- Phase 2 (optional): Create api_requests table for MITM capture
CREATE TABLE kyb.api_requests (
  timestamp        DateTime,
  agent_id         Nullable(String),
  session_id       Nullable(String),
  request_id       String,
  model            String,
  endpoint         String,
  method           String,
  stream           Boolean,
  request_size     UInt32,
  request_messages UInt16,
  request_tokens   Nullable(UInt32),
  response_size    UInt32,
  response_tokens  Nullable(UInt32),
  latency_ms       UInt32,
  ttft_ms          Nullable(UInt32),
  status_code      UInt16,
  error            Nullable(String),
  project          Nullable(String),
  tags             Map(String, String)
) ENGINE = MergeTree
  ORDER BY (project, timestamp)
  SETTINGS index_granularity = 8192;

-- Materialized view: Agent-level API usage summary
CREATE MATERIALIZED VIEW kyb.agent_api_summary
ENGINE = SummingMergeTree
ORDER BY (date, project, agent_id)
AS SELECT
  toDate(timestamp) as date,
  project,
  agent_id,
  count() as api_calls,
  sum(request_tokens) as total_input_tokens,
  sum(response_tokens) as total_output_tokens,
  avg(latency_ms) as avg_latency_ms,
  sum(upload_bytes) as total_upload_mb,
  sum(download_bytes) as total_download_mb
FROM kyb.api_requests
WHERE agent_id IS NOT NULL
GROUP BY date, project, agent_id;
```

### Correlation with agent_events

The key JOIN field is `agent_id + session_id`. To make this work, we need:

1. kyb create/exec to tag containers with agent_id and session_id
2. The channel to propagate this to containers (env vars? labels?)
3. Docker API in the capture poller to read labels

Container labels approach:
```bash
docker run --label agent_id="agent-42" --label session_id="boss-session-5" ...
```

Then the capture poller reads:
```python
container.labels.get("agent_id")
container.labels.get("session_id")
```

---

## Summary: What to Build

| Phase | What | When | Who | Effort |
|-------|------|------|-----|--------|
| 0 | Add `api.deepseek.com` to sing-box routing rules for explicit Claude traffic tagging | ASAP | Infra | 15 min |
| 1 | Enable Clash API, deploy poller container, create `kyb.network_connections` table | ASAP | Infra | 1 day |
| 1.5 | Tag kyb containers with agent_id/session_id labels | Next iteration | kyb dev | 0.5 day |
| 2 | Implement container-name-to-agent correlation in poller | After 1.5 | Infra | 0.5 day |
| 3 | MITM proxy (mitmproxy or custom) for full API capture | If needed | Infra | 3-5 days |

**80/20 recommendation**: Do Phase 1 (1 day). This gives us:
- Connection-level visibility for all Claude sessions
- Per-agent API call volume and timing
- Container-to-agent correlation
- Everything needed for operational dashboards

**Phase 3 (MITM) should NOT be default-on**. It provides full payload capture but at significant complexity and privacy cost. Enable only for specific optimization/debugging sessions.

---

## Appendix: Traffic Capture Points Summary

```
Capture Point                        Data Available              Method
─────────────────────────────────    ────────────────────────    ─────────────────
1. Claude Code process               Full everything             App-level hooks
2. SOCKS5 entry to sing-box (2080)   Domain:port, timing         Access log
3. Sing-box routing engine           Outbound rule matched       Clash API
4. Direct outbound egress            IP:port (TLS-encrypted)     tcpdump
5. Relay outbound egress             IP:port (SS-encrypted)      Not useful
6. MITM proxy (between 2 & 3)        Full HTTP payloads          mitmproxy
7. DeepSeek API server logs          Full everything              Not accessible
```

Point 2 + 3 (sing-box access log + Clash API) gives 80% of operational value with 20% of effort.

Point 6 (MITM) adds 15% more value (token counts, model info, content) but costs 300% more effort.

Point 7 is the ideal — but we don't control DeepSeek's infra.

Point 1 (Claude Code itself) is actually the most powerful: we could instrument the Claude CLI to emit structured events at each API call. But that requires modifying Claude Code itself, which we don't control.
