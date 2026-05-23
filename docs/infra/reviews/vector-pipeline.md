---
decision: 稍后做
---

# Vector Log Pipeline for Infra Containers

> **Status:** Design Document
> **Date:** 2026-05-23
> **Context:** Replace ad-hoc curl-to-ClickHouse logging with a unified Vector-based log shipping pipeline covering all infra containers (cc-connect, boss, patrol, MCP).

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Current State vs Target State](#2-current-state-vs-target-state)
3. [Log Source Breakdown](#3-log-source-breakdown)
4. [Vector Configuration Templates](#4-vector-configuration-templates)
5. [Transform Pipeline](#5-transform-pipeline)
6. [ClickHouse Schemas](#6-clickhouse-schemas)
7. [Deployment](#7-deployment)
8. [Operations](#8-operations)
9. [Implementation Roadmap](#9-implementation-roadmap)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Mac/Orbstack Cluster                        │
│                                                                     │
│  ┌────────────┐   ┌────────────┐   ┌────────────┐   ┌───────────┐  │
│  │ cc-connect │   │   boss     │   │   patrol   │   │ MCP (future)│ │
│  │  (docker)  │   │  (docker)  │   │ (docker)   │   │  (docker)  │  │
│  └─────┬──────┘   └─────┬──────┘   └─────┬──────┘   └─────┬─────┘  │
│        │                │                │                │         │
│        │ docker logs    │ docker logs    │ docker logs    │ docker  │
│        │ socket         │ socket         │ socket         │ logs    │
│        ▼                ▼                ▼                ▼         │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    Vector Container                          │   │
│  │                                                              │   │
│  │  Sources:           Transforms:             Sinks:           │   │
│  │  ┌─────────┐       ┌──────────────┐       ┌───────────┐     │   │
│  │  │ docker_ │       │ parse_kv     │       │ clickhouse│     │   │
│  │  │ logs    │──────▶│ parse_json   │──────▶│ _cc_msg   │     │   │
│  │  │(all     │       │ parse_go_dur │       ├───────────┤     │   │
│  │  │ infra   │       │ join_msg_id  │       │ clickhouse│     │   │
│  │  │contain.)│       │ enrich       │       │ _boss_ops │     │   │
│  │  └─────────┘       │ route_events │       ├───────────┤     │   │
│  │                    │ add_cluster  │       │ clickhouse│     │   │
│  │                    │ _metadata    │       │ _patrol   │     │   │
│  │                    └──────────────┘       ├───────────┤     │   │
│  │                                            │ clickhouse│     │   │
│  │                                            │ _mcp_logs │     │   │
│  │                                            └───────────┘     │   │
│  └──────────────────────┬───────────────────────────────────────┘   │
│                         │                                           │
│                         │ HTTP/INSERT                              │
│                         ▼                                           │
│              ┌──────────────────┐                                   │
│              │   ClickHouse     │                                   │
│              │  (host.orb.int..)│                                   │
│              │  port 8123       │                                   │
│              └────────┬─────────┘                                   │
│                       │                                             │
│                       ▼                                             │
│              ┌──────────────────┐                                   │
│              │    Grafana       │                                   │
│              └──────────────────┘                                   │
└─────────────────────────────────────────────────────────────────────┘

Remote clusters (Aliyun, Office):
  Each runs its own Vector (or direct-curl fallback for heartbeats).
  Central CK on Mac is always the single sink.
```

### Design Principles

1. **Single Vector instance per cluster** -- Collects logs from all infra containers on that host. One process to monitor, one config to manage.
2. **Docker log API as source layer** -- Vector reads container stdout/stderr via the Docker socket. No log files to manage, no sidecar containers, no application changes.
3. **Fail-open by default** -- If CK is unreachable, Vector buffers to disk (or drops on full buffer). Infra containers are never blocked by the log pipeline.
4. **Container label-based discovery** -- Vector auto-discovers infra containers via Docker label `kyb.logs=true`. No per-container config changes needed when adding new services.
5. **Cluster metadata injection** -- Every event is enriched with `cluster`, `host`, and `container_name` at the source, enabling multi-cluster querying in a single CK database.

### Component Diagram Detail

```
                          ┌───────────────────────────┐
                          │     Vector topology        │
                          │                            │
Source layer:             │                            │
  docker_logs (auto) ────▶│  remap / parser transforms │────▶ CK sink (cc.*)
  docker_logs (auto) ────▶│  remap / join transforms   │────▶ CK sink (boss.*)
  docker_logs (auto) ────▶│  remap / route transforms  │────▶ CK sink (patrol.*)
  docker_logs (auto) ────▶│  remap transforms          │────▶ CK sink (mcp.*)
                          │                            │
                          │  Buffer: disk-backed        │
                          │  Ack: end-to-end            │
                          └───────────────────────────┘
```

---

## 2. Current State vs Target State

### Current State

| Service | Log Method | Storage | Reliability | Notes |
|---------|-----------|---------|-------------|-------|
| cc-connect | Go `slog` key=value to stdout | None (ephemeral) | None | `docker logs` only; lost on container restart |
| boss (Claude hooks) | Shell script (emit-ck.sh) | CK via direct HTTP POST | Fail-open (no retry) | Works but is inline; blocks PreToolUse up to 5s |
| boss (heartbeats) | Shell loop (`while true; curl`) | CK via direct HTTP POST | No retry, no buffer | 60s interval; loses heartbeats on CK downtime |
| patrol | File-based `.kyb-diaries/*.md` | Local filesystem | None (lost if container dies) | Not shipped; git-push-based persistence |
| MCP | Not deployed | N/A | N/A | Plan for JSON-structured logs |

### Target State

| Service | Log Method | Vector Source | Transform | CK Table |
|---------|-----------|--------------|-----------|----------|
| cc-connect | Docker logs (stdout) | `docker_logs` with label | `parse_kv` → `parse_go_dur` → `join_msg_id` → `enrich` | `cc.message_log` |
| boss (hooks) | Keep emit-ck.sh OR migrate to Vector | `docker_logs` (accept both) | `parse_json` → `enrich` | `kyb.claude_hook_events` (existing) |
| boss (heartbeats) | Shell loop → migrate to Vector heartbeat generator | N/A (generated inside Vector) | `remap` → `add_cluster_metadata` | `boss_heartbeats` (existing) |
| patrol | Docker logs (stdout) | `docker_logs` with label | `parse_text` → `extract_state` → `route` | `patrol.health_checks` |
| MCP | Docker logs (stdout JSON) | `docker_logs` with label | `parse_json` → `enrich` | `mcp.request_log` |

---

## 3. Log Source Breakdown

### 3.1 cc-connect

**Container:** `feishu-bridge` (or similar)
**Log format:** Go `slog` key=value on stdout, NOT JSON. Two event types that need joining.

**Example lines:**

```
time=2026-05-23T16:38:00.604Z level=INFO msg="turn complete" session=s1 agent_session=d2720c67-... msg_id=om_x... tools=2 response_len=554 turn_duration=4h13m27.227059634s input_tokens=431 output_tokens=521

time=2026-05-23T16:37:37.828Z level=INFO msg="message received" platform=feishu msg_id=om_x... session=feishu:oc_...:ou_... user=ou_... content_len=65 has_images=false has_audio=false has_files=false

time=2026-05-23T16:39:03.343Z level=INFO msg="permission request" request_id=... tool=Bash

time=2026-05-23T16:37:55.717Z level=WARN msg="slow agent send" elapsed=... session=... content_len=...
```

**Parsing requirements:**
- Key=value parser (not JSON)
- `msg` field maps to `event_type` via lookup table
- `session=feishu:oc_...:ou_...` extract `chat_id` (second colon segment) and `sender_id` (third segment)
- `turn_duration` Go duration string (`4h13m27.227059634s`) → Float64 seconds
- Debug lines (`[Debug]` prefix) are unstructured -- drop or store raw
- **Join required:** "message received" (inbound) + "turn complete" (outbound) on `msg_id` to produce a single consolidated record

**Labels for auto-discovery:**
```yaml
labels:
  kyb.logs: "true"
  kyb.service: "cc-connect"
```

### 3.2 Boss (infra-boss container)

**Container:** `infra-boss` or `kyb-infra-boss`
**Log sources within the boss container:**

1. **Claude Code hook events** (already sent to CK via emit-ck.sh)
   - JSON events via shell script
   - Already working, fail-open
   - Optionally migrate to Vector for buffering/retry

2. **Boss stdout/stderr** (Claude agent dialog, tool calls)
   - Free-text logs from the Claude session running inside the boss
   - Not structured; use for alerting on keywords (CRITICAL, ERROR, panic)

3. **Agent dispatch logs** (kyb CLI output, git operations)
   - Mix of structured and unstructured

**Labels for auto-discovery:**
```yaml
labels:
  kyb.logs: "true"
  kyb.service: "boss"
```

### 3.3 Patrol

**Container:** Patrol runs as a container with periodic health checks.
**Log format:** Structured text lines on stdout at each patrol cycle.

**Expected output format (to be designed):**
```
patrol_id=p1 cycle=1743 timestamp=2026-05-23T16:35:00Z status=green cluster=mac-orbstack containers=12/12 healthy disk_used_pct=45
patrol_id=p2 cycle=871 timestamp=2026-05-23T16:37:00Z status=green cluster=mac-orbstack containers=12/12 healthy disk_used_pct=45
patrol_id=p3 cycle=435 timestamp=2026-05-23T16:39:00Z status=yellow cluster=mac-orbstack containers=12/12 healthy disk_used_pct=85 detail="disk approaching limit"
```

**Notes:** Patrol currently logs to `.kyb-diaries/` files. The containerized patrol should output structured key=value lines to stdout, which Vector picks up via docker logs.

**Labels for auto-discovery:**
```yaml
labels:
  kyb.logs: "true"
  kyb.service: "patrol"
```

### 3.4 MCP (Future)

**Container:** `mcp-server-*` (one per MCP server)
**Log format:** Predictable JSON lines on stdout (designed from scratch).

**Expected output format (to be designed):**
```json
{"event":"call_start","ts":"2026-05-23T16:40:00.000Z","server":"filesystem","tool":"read_file","params_size":128}
{"event":"call_end","ts":"2026-05-23T16:40:00.150Z","server":"filesystem","tool":"read_file","status":"ok","latency_ms":150,"output_size":4096}
{"event":"error","ts":"2026-05-23T16:40:05.000Z","server":"database","tool":"query","error":"timeout","retry_count":2}
```

**Labels for auto-discovery:**
```yaml
labels:
  kyb.logs: "true"
  kyb.service: "mcp"
```

### 3.5 Remote Cluster Heartbeats

**Currently:** Shell loops curl heartbeats from Aliyun/Office bosses to central CK.
**Target:** Keep the shell loop (it's simple and works). Vector on the remote cluster is optional; the heartbeat curl is reliable enough for 60s interval data.

**When to add Vector on remote clusters:**
- When cc-connect or other structured-log containers run there
- When heartbeat volume exceeds what shell-loop can handle
- When disk buffering is needed for CK downtime resilience

---

## 4. Vector Configuration Templates

### 4.1 Main Vector Config (vector.toml)

```toml
# /etc/vector/vector.toml
# Single config for all infra containers on this cluster.

[api]
enabled = true
address = "0.0.0.0:8686"  # Vector management API, for health checks

###############################################################################
# GLOBAL
###############################################################################

data_dir = "/var/lib/vector"

###############################################################################
# SOURCES
###############################################################################

# Auto-discover infra containers via Docker label kyb.logs=true
[sources.docker_infra]
type = "docker_logs"
docker_host = "unix:///var/run/docker.sock"
auto_partial_merge = true
auto_partial_merge_wait_ms = 2000
# Use label-based filtering instead of include/exclude lists
# Vector auto-discovers all running containers and emits Docker labels as
# event metadata (container_name, container_id, labels.*).
# We route by kyb.service label in the transform layer.

# For clusters without Docker socket access (e.g., non-Docker envs):
# Use a file-based source as fallback:
[sources.infra_logs_fallback]
type = "file"
include = ["/var/log/infra/*.log"]
ignore_older_secs = 86400

###############################################################################
# TRANSFORMS - cc-connect pipeline
###############################################################################

# Step 1: Filter only cc-connect events
[transforms.filter_cc_connect]
type = "filter"
inputs = ["docker_infra"]
condition = '.container_name == "feishu-bridge" || .labels."kyb.service" == "cc-connect"'

# Step 2: Parse Go slog key=value format into structured fields
[transforms.parse_cc_kv]
type = "remap"
inputs = ["filter_cc_connect"]
source = '''
  # Parse key=value format: time=... level=INFO msg="turn complete" ...
  # Vector's parse_key_value handles quoted values
  parsed = parse_key_value!(.message, field_delimiter: " ")

  # Extract fields from parsed key=value pairs
  .event_time = parsed.time
  .log_level = parsed.level
  .msg = parsed.msg

  # Map msg string to event_type
  if .msg == "turn complete" {
    .event_type = "message_sent"
  } else if .msg == "message received" {
    .event_type = "message_received"
  } else if .msg == "permission request" {
    .event_type = "permission_request"
  } else if .msg == "permission resolved" {
    .event_type = "permission_resolved"
  } else if find(.msg, "slow agent") != null {
    .event_type = "slow_agent_send"
  } else {
    .event_type = "other"
  }

  # Extract known fields from parsed key-value pairs
  .msg_id = parsed.msg_id
  .session = parsed.session
  .agent_session = parsed.agent_session
  .user = parsed.user
  .content_len = to_int!(parsed.content_len) ?? 0
  .has_images = parsed.has_images == "true"
  .has_audio = parsed.has_audio == "true"
  .has_files = parsed.has_files == "true"
  .platform = parsed.platform

  # Turn-complete specific fields
  .tools = to_int!(parsed.tools) ?? 0
  .response_len = to_int!(parsed.response_len) ?? 0
  .turn_duration_raw = parsed.turn_duration
  .input_tokens = to_int!(parsed.input_tokens) ?? 0
  .output_tokens = to_int!(parsed.output_tokens) ?? 0

  # Permission-specific fields
  .request_id = parsed.request_id
  .tool_name = parsed.tool

  # Extract chat_id and sender_id from session field
  # session format: feishu:oc_CHATID:ou_USERID
  if exists(.session) {
    parts = split(.session, ":")
    if length(parts) >= 3 {
      .chat_id = parts[1]
      .sender_id = parts[2]
    } else if length(parts) >= 2 {
      .chat_id = parts[1]
    }
  }

  # Fallback: user field is sender_id when session parsing fails
  if !exists(.sender_id) {
    .sender_id = .user ?? ""
  }

  # Convert turn_duration from Go duration string to Float64 seconds
  # format: 4h13m27.227059634s, 2.941035153s, 500ms
  if exists(.turn_duration_raw) {
    .turn_duration = parse_go_duration(.turn_duration_raw)
  } else {
    .turn_duration = 0.0
  }

  # Timestamp normalization
  .timestamp = parse_timestamp!(.event_time, format: "%+") ?? now()

  # Drop raw message after parsing
  del(.message)
'''

# Step 3: Consolidate inbound + outbound records on msg_id
# Vector's stateful transform merges "message_received" and "message_sent"
# events sharing the same msg_id into a single consolidated record.
[transforms.join_cc_msg]
type = "remap"
inputs = ["parse_cc_kv"]
source = '''
  # This transform enriches each event with all available fields.
  # The actual msg_id-based join is handled by the downstream sink.
  # We tag the side of the conversation for query-time joining.
  if .event_type == "message_received" {
    .direction = "inbound"
  } else if .event_type == "message_sent" {
    .direction = "outbound"
  }
'''

# Alternative: Use a reduce transform for real-time msg_id join
[transforms.reduce_cc_msg]
type = "reduce"
inputs = ["parse_cc_kv"]
group_by = ["msg_id"]
starts_when = '.event_type == "message_received"'
ends_when = '.event_type == "message_sent" || .event_type == "permission_request"'
merge_strategies.struct = "merge"
when_full = "wait_for_timeout"
timeout_ms = 300000  # 5 min max wait for turn complete
source = '''
  # Merge all events in the group into a single consolidated record
  .event_time = .event_time ?? now()
  .event_type = "message_turn"
  .trace_id = .msg_id
'''

###############################################################################
# TRANSFORMS - boss pipeline
###############################################################################

[transforms.filter_boss]
type = "filter"
inputs = ["docker_infra"]
condition = '.container_name == "infra-boss" || .container_name == "kyb-infra-boss" || .labels."kyb.service" == "boss"'

# Parse JSON hook events if they appear on stdout (optional migration path)
[transforms.parse_boss_json]
type = "remap"
inputs = ["filter_boss"]
source = '''
  # Try to parse as JSON (hook events)
  if is_string(.message) {
    result = parse_json(.message)
    if !is_null(result) {
      # Looks like a structured hook event
      . = merge(., result)
      .event_source = "claude_hook"
      del(.message)
    } else {
      # Unstructured log line from boss agent
      .event_source = "agent_log"
      .content = .message
      # Keep .message as-is for keyword alerting
    }
  }
'''

# Route boss events to appropriate CK tables
[transforms.route_boss]
type = "route"
inputs = ["parse_boss_json"]
route.claude_hooks = '.event_source == "claude_hook"'
route.agent_logs = '.event_source == "agent_log" || .event_source == null'
route.heartbeats = 'exists(.boss_id) || contains(.message ?? "", "heartbeat")'

###############################################################################
# TRANSFORMS - patrol pipeline
###############################################################################

[transforms.filter_patrol]
type = "filter"
inputs = ["docker_infra"]
condition = '.labels."kyb.service" == "patrol"'

[transforms.parse_patrol_kv]
type = "remap"
inputs = ["filter_patrol"]
source = '''
  # Parse patrol structured output
  parsed = parse_key_value!(.message, field_delimiter: " ")

  .patrol_id = parsed.patrol_id
  .cycle = to_int!(parsed.cycle) ?? 0
  .status = parsed.status
  .cluster = parsed.cluster
  .containers_healthy = parsed.containers
  .disk_used_pct = to_int!(parsed.disk_used_pct) ?? 0
  .detail = parsed.detail
  .timestamp = now()
  del(.message)
'''

###############################################################################
# TRANSFORMS - MCP pipeline (future)
###############################################################################

[transforms.filter_mcp]
type = "filter"
inputs = ["docker_infra"]
condition = '.labels."kyb.service" == "mcp"'

[transforms.parse_mcp_json]
type = "remap"
inputs = ["filter_mcp"]
source = '''
  result = parse_json(.message)
  if !is_null(result) {
    . = merge(., result)
    .event_source = "mcp"
    del(.message)
  }
'''

###############################################################################
# TRANSFORMS - enrichment (applied to all events)
###############################################################################

[transforms.add_cluster_metadata]
type = "remap"
inputs = [
  "join_cc_msg",
  "reduce_cc_msg",
  "parse_boss_json",
  "parse_patrol_kv",
  "parse_mcp_json",
]
source = '''
  # Cluster identity (injected via environment variable or config)
  .cluster = get_env_var!("VECTOR_CLUSTER") ?? "mac-orbstack"
  .host = get_env_var!("HOSTNAME") ?? sys.hostname()

  # Event arrival time
  .ingested_at = now()

  # Ensure timestamp field exists
  if !exists(.timestamp) {
    .timestamp = now()
  }
'''

###############################################################################
# SINKS
###############################################################################

# cc-connect message log
[sinks.clickhouse_cc_messages]
type = "clickhouse"
inputs = ["add_cluster_metadata"]
endpoint = "http://host.orb.internal:8123"
database = "cc"
table = "message_log"
auth.strategy = "none"
encoding.timestamp_format = "unix"
batch.timeout_secs = 5
batch.max_events = 1000
buffer.type = "memory"
buffer.max_events = 10000
buffer.when_full = "drop_newest"
healthcheck.enabled = false

# Filter: only cc-connect message events land here
[sinks.clickhouse_cc_messages.inputs]
type = "filter"
condition = '''
  .event_type == "message_received" ||
  .event_type == "message_sent" ||
  .event_type == "message_turn"
'''

# Boss claude hook events (replaces emit-ck.sh for stdout events)
[sinks.clickhouse_boss_hooks]
type = "clickhouse"
inputs = ["add_cluster_metadata"]
endpoint = "http://host.orb.internal:8123"
database = "kyb"
table = "claude_hook_events"
encoding.timestamp_format = "unix"
batch.timeout_secs = 5
batch.max_events = 200
healthcheck.enabled = false

[sinks.clickhouse_boss_hooks.inputs]
type = "filter"
condition = '.event_source == "claude_hook" && exists(.event)'

# Boss agent logs (keyword alerting, debugging)
[sinks.clickhouse_boss_logs]
type = "clickhouse"
inputs = ["add_cluster_metadata"]
endpoint = "http://host.orb.internal:8123"
database = "boss"
table = "agent_log"
encoding.timestamp_format = "unix"
batch.timeout_secs = 10
batch.max_events = 500
buffer.type = "disk"
buffer.max_size = 104857600  # 100 MB disk buffer
healthcheck.enabled = false

[sinks.clickhouse_boss_logs.inputs]
type = "filter"
condition = '.event_source == "agent_log"'

# Patrol health check records
[sinks.clickhouse_patrol]
type = "clickhouse"
inputs = ["add_cluster_metadata"]
endpoint = "http://host.orb.internal:8123"
database = "patrol"
table = "health_checks"
encoding.timestamp_format = "unix"
batch.timeout_secs = 5
batch.max_events = 100
healthcheck.enabled = false

[sinks.clickhouse_patrol.inputs]
type = "filter"
condition = 'exists(.patrol_id)'

# MCP request logs (future)
[sinks.clickhouse_mcp]
type = "clickhouse"
inputs = ["add_cluster_metadata"]
endpoint = "http://host.orb.internal:8123"
database = "mcp"
table = "request_log"
encoding.timestamp_format = "unix"
batch.timeout_secs = 5
batch.max_events = 500
healthcheck.enabled = false

[sinks.clickhouse_mcp.inputs]
type = "filter"
condition = '.event_source == "mcp"'
```

### 4.2 Docker Compose Overlay for Vector

```yaml
# docker-compose.vector.yml
# Run alongside existing infra containers on the same Docker network.
version: "3.8"
services:
  vector:
    image: timberio/vector:0.42.0-alpine
    container_name: kyb-infra-vector
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./vector/vector.toml:/etc/vector/vector.toml:ro
      - vector-data:/var/lib/vector
    environment:
      - VECTOR_CLUSTER=mac-orbstack
      - HOSTNAME=infra-boss
      - NO_PROXY=host.orb.internal,localhost,127.0.0.1
    ports:
      - "8686:8686"  # Vector API (health checks)
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  vector-data:
```

### 4.3 CLI Deploy Commands

```bash
# Deploy Vector container
docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /home/dev/vector.toml:/etc/vector/vector.toml:ro \
  -v vector-data:/var/lib/vector \
  -e VECTOR_CLUSTER=mac-orbstack \
  -e HOSTNAME=infra-boss \
  -e NO_PROXY=host.orb.internal,localhost,127.0.0.1 \
  -p 8686:8686 \
  timberio/vector:0.42.0-alpine

# Verify Vector is running and healthy
curl -s http://localhost:8686/health

# Check Vector metrics
curl -s http://localhost:8686/metrics | grep vector_component_received
```

### 4.4 Per-Cluster Configuration

Each cluster host maps `VECTOR_CLUSTER` to its cluster name for metadata injection:

| Cluster | Host | Vector Container Name | VECTOR_CLUSTER |
|---------|------|----------------------|----------------|
| Mac/Orbstack | dongqs-mac | kyb-infra-vector | mac-orbstack |
| Aliyun | sim (47.100.71.220) | kyb-infra-vector | aliyun |
| Office | nuc8 (100.98.29.39) | kyb-infra-vector | office |

On remote clusters (Aliyun, Office), the vector config is identical except:
- `endpoint` points to `http://100.104.244.99:8123` (central CK over Tailscale)
- `VECTOR_CLUSTER` set accordingly
- Docker labels propagate cluster metadata from source

---

## 5. Transform Pipeline

### 5.1 Go Duration Parser (VRL function)

```coffee
# Transforms Go time.Duration strings to Float64 seconds
# Input examples: "4h13m27.227059634s" -> 15207.227
#                  "2.941035153s"       -> 2.941
#                  "500ms"              -> 0.5
#                  "1m30s"              -> 90.0
#
# This is implemented as a VRL function in the remap transform.

# Parsing logic:
# 1. Strip trailing 's'
# 2. Check for 'h', 'm', 'ms' components
# 3. Convert each to seconds and sum
# 4. Return Float64

# VRL-based implementation (inlined in the remap transform above):
. = parse_duration!(.turn_duration_raw, unit: "seconds") ?? 0.0
# Note: Vector does not have a built-in Go duration parser.
# The remap transform uses parse_duration which expects ISO 8601 duration.
# For Go duration format, we implement a custom VRL function below.
```

**Custom VRL function for Go duration parsing** (add to vector config as a `remap` transform):

```coffee
[transforms.parse_go_duration]
type = "remap"
inputs = ["filter_cc_connect"]
source = '''
  # Parse Go time.Duration string manually
  raw = string!(.turn_duration_raw) ?? "0s"

  # Handle pure nanoseconds suffix
  if ends_with(raw, "ns") && !ends_with(raw, "ms") {
    .turn_duration_seconds = to_float!(trim_suffix(raw, "ns")) * 0.000000001
  } else if ends_with(raw, "us") || ends_with(raw, "µs") {
    .turn_duration_seconds = to_float!(trim_suffix(raw, replace(raw, raw, "us", "", "µs", ""))) * 0.000001
  } else if ends_with(raw, "ms") {
    .turn_duration_seconds = to_float!(trim_suffix(raw, "ms")) * 0.001
  } else if ends_with(raw, "s") && !ends_with(raw, "m") {
    # Could be "2.941035153s" or "1m30s"
    raw_no_s = trim_suffix(raw, "s")
    if contains(raw_no_s, "h") || contains(raw_no_s, "m") {
      # Complex: 4h13m27.227059634 -> manual parse
      .turn_duration_seconds = parse_complex_go_duration(raw_no_s)
    } else {
      .turn_duration_seconds = to_float!(raw_no_s) ?? 0.0
    }
  } else {
    .turn_duration_seconds = 0.0
  }
'''

# Helper for complex durations like "4h13m27.227059634"
def parse_complex_go_duration(s) -> float {
  total = 0.0

  # Extract hours
  parts = split(s, "h")
  if length(parts) >= 2 {
    total = total + (to_float!(parts[0]) * 3600.0)
    s = parts[1]
  }

  # Extract minutes
  parts = split(s, "m")
  if length(parts) >= 2 {
    total = total + (to_float!(parts[0]) * 60.0)
    s = parts[1]
  }

  # Remaining is seconds
  if s != "" && s != "0" {
    total = total + to_float!(s)
  }

  total
}
```

### 5.2 Session Field Parser

```coffee
# session field: "feishu:oc_CHATID:ou_USERID"
# or variations: "feishu:oc_CHATID"
#
# Parse into chat_id and sender_id

if exists(.session) {
  parts = split(.session, ":")
  if length(parts) >= 3 {
    .chat_id = parts[1]
    .sender_id = parts[2]
  } else if length(parts) >= 2 {
    .chat_id = parts[1]
    .sender_id = ""
  }
}
```

### 5.3 Event Type Lookup

```coffee
# Map Go slog "msg" values to canonical event_type strings
# for the CK schema.

msg_type_map = {
  "turn complete": "message_sent",
  "message received": "message_received",
  "permission request": "permission_request",
  "permission resolved": "permission_resolved",
  "slow agent send": "slow_agent_send",
}

.event_type = msg_type_map[.msg] ?? "unknown"
```

### 5.4 Enrichment and Metadata

Every event that lands in CK from Vector carries:

| Field | Source | Description |
|-------|--------|-------------|
| `cluster` | `VECTOR_CLUSTER` env var | Which cluster the container runs on |
| `host` | `HOSTNAME` env var | Docker hostname of the container |
| `container_name` | Docker label auto-discovery | Source container name (from Docker socket) |
| `container_id` | Docker log metadata | Source container ID |
| `ingested_at` | Vector `now()` at ingestion | When Vector processed the event |

### 5.5 Transform Flow Diagram

```
                          ┌─────────────────┐
                          │ Docker socket    │
                          │ (all containers) │
                          └────────┬────────┘
                                   │
                          ┌────────▼────────┐
                          │ docker_infra    │
                          │ (Source)        │
                          └────────┬────────┘
                                   │
                    ┌──────────────┼──────────────────┐
                    │              │                   │
            ┌───────▼──────┐ ┌────▼─────┐     ┌──────▼─────┐
            │ filter_cc    │ │filter_boss│     │filter_patrl│
            │ _connect     │ │          │     │            │
            └───────┬──────┘ └────┬─────┘     └──────┬─────┘
                    │              │                   │
            ┌───────▼──────┐ ┌────▼─────┐     ┌──────▼─────┐
            │ parse_cc_kv  │ │parse_boss│     │parse_patrol│
            │ (VRL remap)  │ │ _json    │     │ _kv (remap)│
            └───────┬──────┘ └────┬─────┘     └──────┬─────┘
                    │              │                   │
            ┌───────▼──────┐ ┌────▼─────┐             │
            │ parse_go_dur │ │route_boss│             │
            │ (remap)      │ └┬───┬──┬──┘             │
            └───────┬──────┘  │   │  │                 │
                    │         │   │  │                 │
            ┌───────▼──────┐  │   │  │                 │
            │ reduce_cc_msg│  │   │  │                 │
            │ (join on     │  │   │  │                 │
            │  msg_id)     │  │   │  │                 │
            └───────┬──────┘  │   │  │                 │
                    │         │   │  │                 │
                    └──┬──┬───┘   │  │                 │
                       │  │       │  │                 │
              ┌────────▼──▼───────▼──▼─────────────────▼─────┐
              │          add_cluster_metadata                 │
              │          (remap - enrich all)                 │
              └────────────────────┬─────────────────────────┘
                                   │
                    ┌──────────────┼──────────────────┐
                    │              │                   │
            ┌───────▼──────┐ ┌────▼─────┐     ┌──────▼─────┐
            │ CK sink      │ │ CK sink  │     │ CK sink    │
            │ cc.message   │ │ kyb.claude│    │ patrol.    │
            │ _log         │ │ _hook_   │     │ health_chk │
            │              │ │ events   │     │            │
            └──────────────┘ └──────────┘     └────────────┘
```

---

## 6. ClickHouse Schemas

### 6.1 cc.message_log (Revised)

Incorporating findings from review A1. Compared to the original design:

- **New fields:** `has_audio`, `has_files` (exist in logs, were missing)
- **Modified:** `turn_duration` confirmed as Float64 seconds (requires Go duration parsing)
- **Relaxed:** `content_text` nullable (not available in logs; cc-connect only logs `content_len`)
- **Added:** `direction`, `cluster`, `container_name` (from Vector enrichment)
- **Removed:** `trace_id` (not reliably available from INFO-level slog lines)
- **Added compound sort key:** `msg_id` as secondary (to support join queries)

```sql
CREATE TABLE cc.message_log (
    -- Timestamps
    event_time      DateTime64(3),
    ingested_at     DateTime64(3) DEFAULT now64(),

    -- Event classification
    event_type      LowCardinality(String),
    direction       LowCardinality(String),
    msg             String,

    -- Identifiers
    msg_id          String,
    session         String,
    chat_id         String,
    sender_id       String,
    agent_session   String,

    -- Message metadata
    content_len     UInt32,
    content_text    Nullable(String),
    has_images      UInt8,
    has_audio       UInt8,
    has_files       UInt8,
    message_type    LowCardinality(String),

    -- Turn metrics (outbound only)
    response_len    UInt32,
    turn_duration   Float64,
    input_tokens    UInt32,
    output_tokens   UInt32,
    tools_used      UInt8,

    -- Vector enrichment
    cluster         LowCardinality(String),
    container_name  String,
    host            String
) ENGINE = MergeTree
ORDER BY (event_time, msg_id)
TTL event_time + INTERVAL 90 DAY
```

**Indexes:**
```sql
-- For querying by msg_id (join lookups)
ALTER TABLE cc.message_log ADD INDEX idx_msg_id msg_id TYPE set(100) GRANULARITY 1;

-- For chat-level aggregation queries
ALTER TABLE cc.message_log ADD INDEX idx_chat_id chat_id TYPE set(100) GRANULARITY 4;
```

### 6.2 patrol.health_checks

```sql
CREATE TABLE patrol.health_checks (
    timestamp           DateTime64(3),
    ingested_at         DateTime64(3) DEFAULT now64(),

    patrol_id           LowCardinality(String),
    cycle               UInt64,

    status              LowCardinality(String),  -- green, yellow, red
    containers_healthy  String,                  -- "12/12" for display
    containers_running  UInt16,
    containers_total    UInt16,
    disk_used_pct       UInt8,
    detail              String,

    -- Vector enrichment
    cluster             LowCardinality(String),
    container_name      String,
    host                String
) ENGINE = MergeTree
ORDER BY (patrol_id, timestamp)
TTL timestamp + INTERVAL 30 DAY
```

**Design notes:**
- `patrol_id` distinguishes parallel patrol instances (p1, p2, p3)
- `containers_running` and `containers_total` are parsed from `containers_healthy` display string
- 30-day TTL is sufficient; patrol data is point-in-time health snapshots

### 6.3 boss.agent_log

```sql
CREATE TABLE boss.agent_log (
    timestamp       DateTime64(3),
    ingested_at     DateTime64(3) DEFAULT now64(),

    content         String,
    level           LowCardinality(String),

    -- Alert keywords (extracted during ingestion)
    has_error       UInt8 DEFAULT 0,
    has_critical    UInt8 DEFAULT 0,
    has_panic       UInt8 DEFAULT 0,
    error_keyword   String,

    -- Vector enrichment
    cluster         LowCardinality(String),
    container_name  String,
    host            String
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), has_error, has_critical)
TTL toDate(timestamp) + INTERVAL 7 DAY
```

**Design notes:**
- Short 7-day TTL: agent logs are high-volume and low-value after 7 days
- Separate table from claude_hook_events (which has a 30-day TTL)
- Keyword extraction enables fast alert queries without full-text scan

### 6.4 mcp.request_log (Future)

```sql
CREATE TABLE mcp.request_log (
    timestamp       DateTime64(3),
    ingested_at     DateTime64(3) DEFAULT now64(),

    event           LowCardinality(String),  -- call_start, call_end, error
    server          LowCardinality(String),
    tool            String,

    -- Call metrics
    params_size     UInt32,
    latency_ms      UInt32,
    output_size     UInt32,
    status          LowCardinality(String),

    -- Error fields
    error           String,
    retry_count     UInt8,

    -- Vector enrichment
    cluster         LowCardinality(String),
    container_name  String,
    host            String
) ENGINE = MergeTree
ORDER BY (toDate(timestamp), server, tool)
TTL toDate(timestamp) + INTERVAL 30 DAY
```

### 6.5 Migration Note: Existing Tables

Two tables already exist from the ad-hoc era:
- `kyb.claude_hook_events` -- populated by emit-ck.sh, stays as-is
- `boss_heartbeats` -- populated by shell loops, stays as-is

Vector will write to these tables for boss events (after optional migration from emit-ck.sh), but the tables themselves do not need schema changes. The Vector sink maps fields by name.

---

## 7. Deployment

### 7.1 Deploying Vector on Mac/Orbstack

```bash
# Step 1: Create config directory
mkdir -p /home/dev/vector
cp vector.toml /home/dev/vector/vector.toml

# Step 2: Create Docker volume for Vector data (disk buffer)
docker volume create vector-data

# Step 3: Run Vector container
docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /home/dev/vector/vector.toml:/etc/vector/vector.toml:ro \
  -v vector-data:/var/lib/vector \
  -e VECTOR_CLUSTER=mac-orbstack \
  -e HOSTNAME=infra-boss \
  -e NO_PROXY=host.orb.internal,localhost,127.0.0.1 \
  -p 8686:8686 \
  timberio/vector:0.42.0-alpine

# Step 4: Verify Vector is healthy
curl -s http://localhost:8686/health
# Expected: {"ok":true}

# Step 5: Check Vector is discovering infra containers
curl -s http://localhost:8686/metrics | grep docker_logs
# Expected: non-zero counters for each discovered container
```

### 7.2 Adding Container Labels

Each infra container requires the `kyb.logs=true` label for Vector auto-discovery:

```bash
# When creating a new container:
docker run -d \
  --label kyb.logs=true \
  --label kyb.service=cc-connect \
  --name feishu-bridge \
  ...

# For existing containers, re-create with labels or use docker update:
# Note: docker update does not support adding labels to running containers.
# For existing infra containers, update their run commands to include:
docker run ... --label kyb.logs=true --label kyb.service="cc-connect" ...
```

### 7.3 Updating Existing Infra Containers

```bash
# cc-connect: add --label when re-creating
docker stop feishu-bridge
docker rm feishu-bridge
docker run -d \
  --label kyb.logs=true \
  --label kyb.service=cc-connect \
  --name feishu-bridge \
  ... (existing run args)

# infra-boss: add --label when re-creating
docker stop infra-boss
docker rm infra-boss
docker run -d \
  --label kyb.logs=true \
  --label kyb.service=boss \
  --name infra-boss \
  ... (existing run args)
```

### 7.4 Deploying Vector on Remote Clusters

```bash
# On Aliyun (sim):
ssh sim 'docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /home/dongqs/vector.toml:/etc/vector/vector.toml:ro \
  -v vector-data:/var/lib/vector \
  -e VECTOR_CLUSTER=aliyun \
  -e HOSTNAME=kyb-infra-boss \
  -e NO_PROXY=100.104.244.99,localhost,127.0.0.1 \
  -p 8686:8686 \
  timberio/vector:0.42.0-alpine'

# Note: endpoint in remote config points to http://100.104.244.99:8123 (central CK)
```

### 7.5 Verification Checklist

```bash
# 1. Vector process is running
docker ps | grep vector

# 2. Vector health endpoint responds
curl -s http://localhost:8686/health | jq

# 3. Vector sees infra containers in its source
curl -s http://localhost:8686/metrics | grep -E "(docker_logs_events_total|component_received)"

# 4. Data is landing in CK
clickhouse-client --host host.orb.internal \
  --query "SELECT count() FROM cc.message_log WHERE ingested_at > now() - INTERVAL 5 MINUTE"

# 5. Data has correct cluster metadata
clickhouse-client --host host.orb.internal \
  --query "SELECT cluster, count() FROM cc.message_log WHERE ingested_at > now() - INTERVAL 5 MINUTE GROUP BY cluster"
```

---

## 8. Operations

### 8.1 Resource Requirements

| Resource | Estimate | Notes |
|----------|----------|-------|
| CPU | 0.1-0.5 cores | Idle most of the time; spikes on batch flush |
| Memory | 64-128 MB | Vector binary + buffer |
| Disk (buffer) | 100 MB max | Only when CK is unreachable |
| Disk (image) | ~50 MB | Alpine-based vector image |

At the current scale (~90 messages/day cc-connect, ~5000 events/day boss), Vector's resource usage is negligible. The primary cost is operational: one additional container to monitor.

### 8.2 Failure Modes

| Failure | Behavior | Recovery |
|---------|----------|----------|
| CK unreachable | Vector buffers to memory (10K events) then drops oldest | Auto-reconnect; data loss on sustained outage > 10K events |
| CK unreachable (disk buffer) | Vector buffers to disk (100 MB) then drops oldest | Auto-reconnect; no data loss for typical outage durations |
| Vector crashes | All buffered events lost | Docker auto-restart; transient data loss |
| Docker socket unavailable | No new events until socket recovers | Vector retries connection automatically |
| Config syntax error | Vector fails to start | Docker logs show parse error; fix config and restart |
| High event volume spike | Buffer fills, drops oldest events | Scale buffer size or CK write capacity |

### 8.3 Monitoring Vector

```sql
-- Check Vector event throughput per minute
SELECT toStartOfMinute(timestamp) AS minute,
       count() AS events_per_minute
FROM cc.message_log
WHERE timestamp > now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute;

-- Check for gaps in Vector ingestion (Vector might be down)
SELECT toStartOfFiveMinutes(ingested_at) AS period,
       count() AS events,
       countIf(ingested_at < timestamp - INTERVAL 5 SECOND) AS delayed
FROM cc.message_log
WHERE ingested_at > now() - INTERVAL 1 HOUR
GROUP BY period
ORDER BY period;
```

**Alert rule:** If `events_per_minute` drops below the baseline threshold for any cc-connect table, Vector may be down or disconnected.

### 8.4 Vector Health Dashboard in Grafana

Suggested panels:

1. **Events per minute** (line chart, one line per CK table)
2. **Events by cluster** (stacked area, shows per-cluster volume)
3. **Buffer utilization** (gauge, 0-100% of buffer capacity)
4. **Error rate** (events with parsing errors, if any)
5. **Vector uptime** (singular stat)

### 8.5 Fail-Open Guarantee

- Vector buffer is configured to `drop_newest` when full -- never backpressure into the Docker log stream
- If Vector is down, Docker retains logs up to its configured `max-size`/`max-file` limits
- If Vector container crashes, old events are lost but infra containers continue running
- The Claude hook pipeline (emit-ck.sh) continues working independently -- it does NOT depend on Vector
- Heartbeat shell loops continue independently -- they do NOT depend on Vector

This means: **Vector can be down for any reason, and infra containers keep running.** The only impact is missing observability data.

### 8.6 Config Updates

Vector supports hot-reload of config changes without restarting:

```bash
# Edit the config
vim /home/dev/vector/vector.toml

# Reload Vector
docker exec kyb-infra-vector vector validate /etc/vector/vector.toml
docker kill -s SIGHUP kyb-infra-vector

# Or just restart for simplicity
docker restart kyb-infra-vector
```

Validate config before applying:
```bash
docker run --rm -v /home/dev/vector/vector.toml:/etc/vector/vector.toml:ro \
  timberio/vector:0.42.0-alpine vector validate /etc/vector/vector.toml
```

### 8.7 Debugging

```bash
# Check Vector logs
docker logs kyb-infra-vector --tail 50

# Check Vector internal metrics (rich telemetry)
curl -s http://localhost:8686/metrics | head -100

# Check Vector topology (pipelines, transforms, sinks)
curl -s http://localhost:8686/topology | jq .

# Test a specific container log line reaches Vector
# (Inject a test log line into a container Vector is watching)
docker exec feishu-bridge sh -c 'echo "time=2026-05-23T16:40:00Z level=INFO msg=\"test line\" msg_id=test_001" > /proc/1/fd/1'

# Then check it landed:
clickhouse-client --host host.orb.internal \
  --query "SELECT event_type, msg_id FROM cc.message_log WHERE msg_id='test_001'"
```

---

## 9. Implementation Roadmap

### Phase 1: Foundation (Day 1)

- [ ] Deploy Vector container on Mac/Orbstack with minimal config
- [ ] Add `kyb.logs=true` and `kyb.service` labels to existing infra containers (cc-connect, boss)
- [ ] Verify Vector discovers containers via Docker socket
- [ ] Create CK tables: `cc.message_log`, `patrol.health_checks`, `boss.agent_log`, `mcp.request_log`
- [ ] Add a `cc-connect` log source with basic key=value parsing
- [ ] Validate data lands in CK

### Phase 2: Transforms (Day 2)

- [ ] Implement Go duration parser (VRL remap transform)
- [ ] Implement session field parser (chat_id/sender_id extraction)
- [ ] Implement `reduce` transform for msg_id-based join
- [ ] Add `add_cluster_metadata` enrichment
- [ ] Add route transforms to send events to correct tables

### Phase 3: Patrol Integration (Day 3)

- [ ] Add patrol container with structured key=value stdout output
- [ ] Add Vector source and transforms for patrol
- [ ] Create Grafana panel for patrol health trends

### Phase 4: Remote Clusters (Day 4)

- [ ] Deploy Vector on Aliyun (sim)
- [ ] Deploy Vector on Office (nuc8)
- [ ] Verify central CK receives events from all clusters
- [ ] Create multi-cluster Grafana panels

### Phase 5: Future

- [ ] Deploy MCP server container(s)
- [ ] Add MCP log source with JSON parsing
- [ ] Optionally migrate Claude hook pipeline (emit-ck.sh) to Vector
- [ ] Set up alert rules for Vector health
- [ ] Create Vector health dashboard in Grafana
- [ ] Consider disk buffer for remote clusters with less reliable CK connectivity

---

> **Summary:** Vector consolidates all infra container logs into a single pipeline with per-service transforms, cluster metadata enrichment, and ClickHouse sinks. The design is fail-open and layered so each service can be onboarded independently. Resource requirements are minimal at current scale (~0.2 CPU, 64 MB RAM). The key technical challenges are Go duration parsing and msg_id-based log line joining, both addressed with VRL transforms in this document.

> ／人◕ ‿‿ ◕人＼
