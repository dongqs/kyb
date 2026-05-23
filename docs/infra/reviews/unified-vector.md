---
decision: 稍后做
---

# Unified Vector Pipeline for All Infra Logs

**Status:** Design Document
**Date:** 2026-05-23
**Context:** Consolidate 10+ bespoke log pipelines into a single Vector instance collecting from every container on every cluster.

---

## Table of Contents

1. [Motivation: Current Fragmentation](#1-motivation-current-fragmentation)
2. [Architecture Overview](#2-architecture-overview)
3. [Deployment Topology](#3-deployment-topology)
4. [Central Config Structure](#4-central-config-structure)
5. [Multi-Source Ingestion](#5-multi-source-ingestion)
6. [VRL Transform Catalog](#6-vrl-transform-catalog)
7. [Multi-Sink Routing](#7-multi-sink-routing)
8. [ClickHouse Schema Consolidation](#8-clickhouse-schema-consolidation)
9. [Directory & File Layout](#9-directory--file-layout)
10. [Operational Playbook](#10-operational-playbook)
11. [Migration Strategy](#11-migration-strategy)
12. [Resource Estimates](#12-resource-estimates)
13. [Failure Modes](#13-failure-modes)

---

## 1. Motivation: Current Fragmentation

### 1.1 The Problem

Currently, infra log collection is implemented as **10+ bespoke pipelines**, each with its own transport mechanism, failure mode, and configuration:

| Pipeline | Collector | Transport | Buffer | Status |
|----------|-----------|-----------|--------|--------|
| cc-connect logs | Vector (planned) | docker_logs → CK sink | None | Designed, not deployed |
| Claude hooks | Shell script | HTTP POST → CK | None (fail-open) | Running |
| Boss heartbeats | Shell loop | HTTP POST → CK | None (fail-open) | Running |
| Docker events | Shell script | docker events → CK | None | Designed, not deployed |
| Sing-box connection logs | Vector (planned) | docker_logs → CK | None | Designed, not deployed |
| Sing-box metrics | Python poller | HTTP POST → CK | None | Designed, not deployed |
| Patrol OTel traces | File → Vector | file_source → CK | File buffer | Designed, not deployed |
| Error budget | (not built) | — | — | — |
| Proxy intercept | (not built) | — | — | — |
| Fluentd alternative | (standalone design) | forward → CK | File buffer | Speculative |
| Kafka message bus | (standalone design) | Kafka → CK Engine | Kafka topic retention | Speculative |

### 1.2 Pain Points

1. **Config sprawl** -- Vector config is scattered across 6+ design docs (bridge-ck-ingestion, sing-box-metrics, otel-patrol, fluentd-pipeline, docker-events, kafka-message-bus). No single source of truth.

2. **No buffer on critical paths** -- Claude hooks and boss heartbeats use fire-and-forget HTTP POST. If ClickHouse is down, events are lost. Vector's disk buffer handles this automatically.

3. **Inconsistent enrichment** -- Each pipeline adds cluster/host metadata differently (or not at all). Cross-pipeline correlation requires ad-hoc joins across tables.

4. **No unified schema envelope** -- Each CK table has its own column set with no shared `source`, `event_type`, `cluster`, `host` columns. Events from cc-connect and docker-events cannot be correlated in a single query.

5. **Duplicate implementation effort** -- Fluentd, Kafka, and direct-HTTP designs each solve the same transport problem in incompatible ways. A single Vector instance eliminates the need to choose.

6. **No container-level granularity** -- Only cc-connect and sing-box have tailored collection. PG, Redis, Kafka, Grafana, registry cache, and other infra containers have zero structured log collection.

### 1.3 Why Vector (Not Fluentd, Not Kafka)

| Criteria | Vector | Fluentd | Kafka + CK Engine |
|----------|--------|---------|-------------------|
| Single binary | Yes (Rust, ~15 MB) | Ruby + gems (~80 MB) | JVM (~500 MB) + CK Engine |
| ClickHouse sink | Built-in, maintained by DataDog | Community gem | Native (Kafka Engine) |
| Disk buffer | Configurable per sink | Built-in file buffer | Kafka retention (7d) |
| Multi-cluster forward | `vector` source/sink | `forward` protocol | Kafka mirroring |
| VRL transform | Powerful, typed DSL | Ruby DSL (heavier) | SQL-only (CK side) |
| Setup complexity | 1 container, 1 TOML file | 1 container + gems + plugins | 2 containers + topics + MV |
| Resource usage (idle) | ~5-15 MB RSS | ~40-80 MB RSS | ~256 MB (Redpanda) |
| Resource usage (1K/s) | ~20-40 MB RSS | ~120-200 MB RSS | ~300-500 MB |

**Verdict:** Vector wins on resource footprint, built-in CK sink, and single-config simplicity. Fluentd and Kafka address the same problems with more complexity -- they are valid alternatives but not necessary at current scale (~50-1000 events/day per pipeline).

---

## 2. Architecture Overview

### 2.1 Data Flow (Single Cluster)

```
┌────────────────────────────────────────────────────────────────┐
│  Docker Host (Mac/Orbstack, Aliyun, or Office)                 │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  /var/lib/docker/containers/*/*-json.log                 │  │
│  │  (every infra container's stdout/stderr)                  │  │
│  └────────────────────┬─────────────────────────────────────┘  │
│                       │ file source (tail)                      │
│                       ▼                                        │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Vector Container (kyb-infra-vector)                      │  │
│  │                                                           │  │
│  │  Sources:                                                 │  │
│  │    ├─ file     ← Docker json-logs (ALL containers)       │  │
│  │    └─ http     ← Claude hooks, heartbeats (optional)     │  │
│  │                                                           │  │
│  │  Transforms (VRL):                                        │  │
│  │    ├─ parse_docker_json     (unwrap json-file wrapper)    │  │
│  │    ├─ enrich_metadata       (add cluster, host, env)      │  │
│  │    ├─ route_by_container    (tag-based routing)           │  │
│  │    ├─ parse_cc_connect      (Go slog key=value)           │  │
│  │    ├─ parse_singbox_json    (JSON connection logs)        │  │
│  │    ├─ parse_postgres        (PG log lines → structured)  │  │
│  │    ├─ parse_generic         (fallthrough catch-all)       │  │
│  │    └─ build_envelope        (add source/event_type)       │  │
│  │                                                           │  │
│  │  Sinks:                                                   │  │
│  │    ├─ clickhouse (primary, multiple tables)               │  │
│  │    ├─ vector     (forward to central if remote cluster)   │  │
│  │    └─ file       (debug fallback)                         │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

### 2.2 Multi-Cluster Data Flow

```
Mac/Orbstack (Central)                     Aliyun sim (Remote)            Office nuc8 (Remote)
┌─────────────────────┐                   ┌─────────────────────┐        ┌─────────────────────┐
│ Vector (central)    │                   │ Vector (remote)     │        │ Vector (remote)     │
│                     │                   │                     │        │                     │
│ Sources:            │                   │ Sources:            │        │ Sources:            │
│  ├─ file: all logs  │                   │  ├─ file: all logs  │        │  ├─ file: all logs  │
│  └─ vector: remote  │◄──── Tailscale ───┤  └─ vector: forward │        │  └─ vector: forward │
│       ← forwarded   │    ───────────────┤       to central    │        │       to central    │
│                     │    100.104.244.99 │                     │        │                     │
│ Sinks:              │     :6000         │ Sinks:              │        │ Sinks:              │
│  ├─ clickhouse (CK) │                   │  ├─ vector (central)│        │  ├─ vector (central)│
│  ├─ vector (listen) │                   │  └─ file (cache)    │        │  └─ file (cache)    │
│  └─ file (debug)    │                   └─────────────────────┘        └─────────────────────┘
└──────────┬──────────┘
           │ 8123
           ▼
   ┌──────────────┐
   │  ClickHouse  │
   │  infra.*     │
   │  cc.*        │
   │  net.*       │
   │  kyb.*       │
   │  otel.*      │
   └──────────────┘
```

### 2.3 Design Decisions

1. **File source over docker_logs API**: Tailing `/var/lib/docker/containers/*/*-json.log` files is more reliable than Docker's events-based `docker_logs` source. File tail handles rotation, does not depend on Docker API availability, and works identically on all Docker engines (OrbStack, Docker CE). The position file (`data_dir`) persists across Vector restarts.

2. **Single Vector container per host**: Each Docker host runs exactly one `kyb-infra-vector` container. All logs from all containers on that host enter that Vector instance. No sidecars, no per-container agents.

3. **Remote clusters forward to central Vector**: Remote cluster Vectors use the `vector` sink to forward all logs to the central Vector on Mac/Orbstack over Tailscale. The central Vector is the single writer to ClickHouse. This avoids opening CK to remote connections and provides a single point of buffer management.

4. **Disk buffer on all sinks**: Every sink is configured with a `disk` buffer, not `memory`. This survives Vector restarts and absorbs CK downtime.

5. **One config file, version-controlled**: The complete Vector config lives in `/home/dev/projects/kyb/docs/infra/vector/vector.toml` in the kyb repo. Per-cluster overrides (CK endpoint, cluster name) are environment variables.

---

## 3. Deployment Topology

### 3.1 Per-Cluster Vector Container

Each cluster runs the Vector container from the official `timberio/vector` image:

```bash
# Same command on every cluster (Mac/Orbstack, Aliyun, Office)
docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  --network kyb-net \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v vector-data:/var/lib/vector \
  -v /home/dev/projects/kyb/docs/infra/vector:/etc/vector:ro \
  -e VECTOR_CLUSTER_NAME=mac-orbstack \
  -e VECTOR_CLUSTER_ROLE=central \
  --init \
  timberio/vector:0.42.0-alpine \
  --config /etc/vector/vector.toml
```

**Volume mounts:**

| Mount | Purpose |
|-------|---------|
| `/var/lib/docker/containers:ro` | Read Docker json-log files for all containers |
| `vector-data:/var/lib/vector` | Persistent data_dir (position file, disk buffers) |
| `/etc/vector:ro` | Config file bind-mounted from repo checkout |

**Environment variables:**

| Variable | Central (Mac) | Remote (Aliyun) | Remote (Office) |
|----------|--------------|-----------------|-----------------|
| `VECTOR_CLUSTER_NAME` | `mac-orbstack` | `aliyun` | `office` |
| `VECTOR_CLUSTER_ROLE` | `central` | `remote` | `remote` |
| `VECTOR_CK_ENDPOINT` | `http://host.orb.internal:8123` | (unused, forwards) | (unused, forwards) |
| `VECTOR_CENTRAL_ADDR` | (unused, is central) | `100.104.244.99:6000` | `100.104.244.99:6000` |
| `VECTOR_SELF_ADDR` | `0.0.0.0:6000` | (unused) | (unused) |

### 3.2 Central Vector (Mac/Orbstack)

The central Vector:
- **Consumes**: Local docker logs, plus forwarded logs from remote clusters
- **Writes**: ClickHouse directly (primary), file (debug)
- **Listens**: On port 6000 for `vector` protocol connections from remote Vectors

```bash
# Port 6000 must be accessible from remote clusters via Tailscale
docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  --network kyb-infra \
  -p 100.104.244.99:6000:6000 \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v vector-data:/var/lib/vector \
  -v /home/dev/projects/kyb/docs/infra/vector:/etc/vector:ro \
  -e VECTOR_CLUSTER_NAME=mac-orbstack \
  -e VECTOR_CLUSTER_ROLE=central \
  -e VECTOR_CK_ENDPOINT=http://host.orb.internal:8123 \
  --init \
  timberio/vector:0.42.0-alpine \
  --config /etc/vector/vector.toml
```

### 3.3 Remote Vector (Aliyun, Office)

Remote Vectors:
- **Consumes**: Local docker logs
- **Writes**: Forward to central Vector via `vector` sink over Tailscale
- **Buffers**: Disk buffer in case central is unreachable

```bash
# Remote cluster (Aliyun sim example):
docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  --network kyb-infra \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v vector-data:/var/lib/vector \
  -v /home/dev/projects/kyb/docs/infra/vector:/etc/vector:ro \
  -e VECTOR_CLUSTER_NAME=aliyun \
  -e VECTOR_CLUSTER_ROLE=remote \
  -e VECTOR_CENTRAL_ADDR=100.104.244.99:6000 \
  --init \
  timberio/vector:0.42.0-alpine \
  --config /etc/vector/vector.toml
```

Note: `--init` ensures proper signal handling and zombie reaping inside the container. This is critical for Vector's graceful shutdown (flushes buffers before exit).

---

## 4. Central Config Structure

### 4.1 Config File

The single `vector.toml` covers all roles. Conditional logic via environment variables and `if` expressions enables central vs remote behavior:

```toml
# ─────────────────────────────────────────────────────────────
# Vector Unified Config — All Infra Logs
# ─────────────────────────────────────────────────────────────
# One instance per cluster. Central (Mac/Orbstack) writes to CK.
# Remote clusters (Aliyun, Office) forward to central via vector sink.
#
# Env vars:
#   VECTOR_CLUSTER_NAME  — mac-orbstack | aliyun | office
#   VECTOR_CLUSTER_ROLE  — central | remote
#   VECTOR_CK_ENDPOINT   — http://host.orb.internal:8123 (central only)
#   VECTOR_CENTRAL_ADDR  — 100.104.244.99:6000 (remote only)
# ─────────────────────────────────────────────────────────────

# ── Global ──
data_dir = "/var/lib/vector"

# ────────────────────
# Sources
# ────────────────────

# All Docker json-file logs on this host
[sources.docker_logs]
type = "file"
include = ["/var/lib/docker/containers/*/*-json.log"]
# Exclude the Vector container's own logs (infinite loop)
exclude = ["/var/lib/docker/containers/*kyb-infra-vector*/**"]
# Glob minimum offset — start from end (new logs only)
ignore_older_secs = 300

# Claude hooks HTTP endpoint (optional — replaces shell script HTTP POST)
[sources.hook_events]
type = "http"
address = "0.0.0.0:8282"
encoding = "json"
framing = "newline_delimited"

# Central-only: receive forwarded logs from remote clusters
[sources.remote_logs]
type = "vector"
version = "3"
address = "${VECTOR_SELF_ADDR}"
# This source is only active when VECTOR_CLUSTER_ROLE=central
# (unset env var makes the source fail to bind, so remote clusters
#  simply do not configure this or use a conditional)
# Removed: source activation via env var
# The remote Vector sends to central, not the other way around

# ────────────────────
# Transforms
# ────────────────────

# 1. Parse Docker's json-file wrapper: { "log": "...", "stream": "stdout", "time": "..." }
[transforms.parse_docker_wrapper]
type = "remap"
inputs = ["docker_logs"]
source = '''
  # Docker json-file format: {"log":"actual line\n","stream":"stdout","time":"..."}
  # Vector's file source reads the raw JSON line. We need to unwrap it.
  parsed = parse_json!(.message)

  # Override message with actual log content
  .message = parsed.log
  # Trim trailing newline added by Docker
  .message = slice!(.message, 0, length(.message) - 1)
  # Preserve stream (stdout/stderr)
  .stream = parsed.stream
  # Parse the timestamp
  .timestamp = parse_timestamp!(parsed.time, format: "%+") ?? now()

  # Extract container ID from the file path
  # Path: /var/lib/docker/containers/<container_id>/<container_id>-json.log
  parts = split!(.file, "/")
  .container_id = parts[4]  # container SHA256

  # Remove raw message to avoid double-storage
  del(.file)
'''

# 2. Enrich with cluster metadata
[transforms.enrich_metadata]
type = "remap"
inputs = ["parse_docker_wrapper"]
source = '''
  .cluster = get_env!("VECTOR_CLUSTER_NAME") ?? "unknown"
  .host = get_hostname!() ?? "unknown"

  # Add a receive timestamp (separate from log timestamp)
  .ingested_at = now()
'''

# 3. Route by container name
# We determine the container name from Docker labels or by mapping container ID.
# For now, use a heuristic: match container ID against docker ps output.
# A more robust approach: prepopulate a lookup table from docker inspect.
#
# Current infra containers on Mac:
#   kyb-infra-boss, kyb-infra-cc-connect, kyb-infra-clickhouse,
#   kyb-infra-grafana, kyb-infra-kafka, kyb-infra-postgresql-14/15/16/17,
#   kyb-infra-redis, kyb-infra-sing-box, kyb-registry-cache
#
# We use a VRL lookup approach: tag by container_id pattern matched against
# docker events or a static mapping.

[transforms.route_by_container]
type = "remap"
inputs = ["enrich_metadata"]
source = '''
  # Placeholder: in a real deployment, the container_id is mapped to
  # container name via a VRL enrichment table or the Vector enrichment API.
  #
  # For now, we tag all events with a generic "infra" container type.
  # Per-container parsing is activated in downstream transforms.
  .container_type = "generic"
'''

# 4. Build unified schema envelope
[transforms.build_envelope]
type = "remap"
inputs = ["route_by_container"]
source = '''
  # Unified envelope for cross-pipeline correlation
  .schema_version = "1.0"
  .source = "docker_logs"
  .event_type = "container_log"
  .event_time = .timestamp
'''

# 5. Parse Go slog key=value format (cc-connect, Grafana)
[transforms.parse_slog]
type = "remap"
inputs = ["build_envelope"]
source = '''
  # cc-connect and Grafana emit Go slog key=value format:
  #   time=... level=INFO msg="turn complete" msg_id=om_... tools=2 ...
  #
  # Apply only to lines matching the slog pattern
  if match(.message, r'^time=\d{4}') {
    # Extract all key=value pairs
    pairs = parse_key_value!(.message, delimiter: " ", key_value_delimiter: "=")
    .log_level = pairs.level
    .log_msg = pairs.msg

    # Route based on msg value
    .log_source = if pairs.msg == "turn complete" || pairs.msg == "message received" ||
                     match(pairs.msg, r'^(permission_request|permission_resolved)') {
      "cc-connect"
    } else if match(pairs.msg, r'^(Migration|Query|Session)') {
      "grafana"
    } else {
      "unknown"
    }

    # Extract known cc-connect fields
    if .log_source == "cc-connect" {
      .msg_id = pairs.msg_id
      .session = pairs.session
      .user = pairs.user
      .content_len = to_int!(pairs.content_len) ?? 0
      .has_images = to_int!(pairs.has_images) ?? 0
      .tools = to_int!(pairs.tools) ?? 0
      .response_len = to_int!(pairs.response_len) ?? 0
      .turn_duration = parse_duration(pairs.turn_duration) ?? 0.0
      .input_tokens = to_int!(pairs.input_tokens) ?? 0
      .output_tokens = to_int!(pairs.output_tokens) ?? 0
    }

    # Override envelope for structured events
    .event_type = "structured_log"
    .source = .log_source ?? "slog"
  }
'''

# 6. Parse sing-box JSON logs
[transforms.parse_singbox]
type = "remap"
inputs = ["parse_slog"]
source = '''
  # sing-box emits JSON lines like:
  # {"level":"info","time":"...","message":"inbound/redir: started"}
  # Or connection close events with "type":"connection"
  if match(.message, r'^\s*\{') {
    parsed = parse_json!(.message)

    # Check if it's a structured JSON log
    if parsed != null {
      .log_level = parsed.level
      .log_msg = parsed.message

      # Connection close events have type="connection"
      if parsed.type == "connection" && parsed.payload != null {
        .event_type = "connection_close"
        .source = "sing-box"
        .outbound_tag = parsed.payload.outbound
        .network = parsed.payload.network
        .destination = parsed.payload.destination
        .bytes_upload = to_int!(parsed.payload.upload) ?? 0
        .bytes_download = to_int!(parsed.payload.download) ?? 0
        .duration_ms = to_int!(parsed.payload.duration) ?? 0
        .rule_tag = parsed.payload.rule
      }
    }
  }
'''

# 7. Extract PostgreSQL log fields (if log line matches PG format)
[transforms.parse_postgres]
type = "remap"
inputs = ["parse_singbox"]
source = '''
  # PG stderr format:
  # 2026-05-23 16:38:00.604 CST [12345] LOG:  checkpoint starting: time
  if match(.message, r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \w+ \[\d+\] \w+:') {
    parts = parse_regex!(.message, r'^(?P<pg_timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \w+) \[(?P<pid>\d+)\] (?P<pg_level>\w+):\s+(?P<message>.*)')
    .log_level = parts.pg_level
    .log_source = "postgres"
    .pg_pid = to_int!(parts.pid) ?? 0
    .message = parts.message
    .event_type = "database_log"
    .source = "postgres"
  }
'''

# 8. Build the canonical event payload (flatten all known fields, add raw fallback)
[transforms.canonicalize]
type = "remap"
inputs = ["parse_postgres"]
source = '''
  # Flatten to canonical event: every row has this shape
  .payload_raw = encode_json(.) ?? .message
'''

# ────────────────────
# Sinks
# ────────────────────

# Primary: ClickHouse message_log (all structured events)
[sinks.clickhouse_message_log]
type = "clickhouse"
inputs = ["canonicalize"]
endpoint = "${VECTOR_CK_ENDPOINT}"
database = "infra"
table = "message_log"
compression = "lz4"
healthcheck = true

[sinks.clickhouse_message_log.buffer]
type = "disk"
max_size = 268435488  # 256 MB
when_full = "block"

[sinks.clickhouse_message_log.batch]
max_events = 500
timeout_secs = 2

[sinks.clickhouse_message_log.request]
timeout_secs = 30
retry_initial_backoff_secs = 1
retry_max_duration_secs = 300

# Remote clusters: forward to central Vector
[sinks.forward_to_central]
type = "vector"
version = "3"
inputs = ["canonicalize"]
address = "${VECTOR_CENTRAL_ADDR}"

[sinks.forward_to_central.buffer]
type = "disk"
max_size = 268435488  # 256 MB
when_full = "block"

# Debug sink (all events, compressed JSON lines)
[sinks.debug_file]
type = "file"
inputs = ["canonicalize"]
path = "/var/log/vector/debug.log"
encoding.codec = "json"
compression = "gzip"

# ────────────────
# Healthcheck
# ────────────────
[healthcheck]
enabled = true
require_healthy = false  # Don't block startup on CK unavailability
```

### 4.2 Env-Specific Config Injection

Rather than maintaining separate config files per cluster, the single `vector.toml` uses environment variables for cluster-specific values. The config file is checked into the kyb repo at:

```
docs/infra/vector/vector.toml
```

The `vector` source on the central side is configured to listen, and remote Vectors connect to it. To handle the fact that only the central Vector should listen, we use a wrapper script or a separate config snippet:

**Central override** (`/etc/vector/central.toml`, only on Mac/Orbstack):

```toml
[sources.remote_logs]
type = "vector"
version = "3"
address = "0.0.0.0:6000"
```

This is loaded as a second config file:

```bash
# Central:
vector --config /etc/vector/vector.toml --config /etc/vector/central.toml

# Remote:
vector --config /etc/vector/vector.toml
```

### 4.3 Config Change Management

Vector supports hot-reload via SIGHUP:

```bash
# After editing vector.toml:
docker exec kyb-infra-vector sh -c "kill -HUP 1"

# Verify reload:
docker exec kyb-infra-vector vector top
```

Config changes are made via git:

```bash
# 1. Edit in repo
vim docs/infra/vector/vector.toml

# 2. Commit and push
git add docs/infra/vector/vector.toml
git commit -m "feat: update unified Vector config"
git push

# 3. Deploy to each cluster
#    Mac (local):
docker cp docs/infra/vector/vector.toml kyb-infra-vector:/etc/vector/
docker exec kyb-infra-vector sh -c "kill -HUP 1"

#    Remote (via SSH dispatch):
ssh sim "docker cp /home/dev/projects/kyb/docs/infra/vector/vector.toml kyb-infra-vector:/etc/vector/ && docker exec kyb-infra-vector sh -c 'kill -HUP 1'"
ssh nuc8 "docker exec kyb-infra-vector sh -c 'cp /home/dev/projects/kyb/docs/infra/vector/vector.toml /etc/vector/ && kill -HUP 1'"
```

---

## 5. Multi-Source Ingestion

### 5.1 File Source: Docker Container Logs

This is the primary source, covering every container on the host.

**Path pattern:** `/var/lib/docker/containers/*/*-json.log`

Docker's `json-file` log driver writes each line as:

```json
{"log":"actual log line\n","stream":"stdout","time":"2026-05-23T16:38:00.604Z"}
```

Vector's `file` source reads the raw file. The `parse_docker_wrapper` transform unwraps the JSON.

**Containers collected (all infra containers):**

| Container | Log Format | Expected Volume | Structured Parsing |
|-----------|-----------|-----------------|-------------------|
| `kyb-infra-boss*` | Generic stdout | Low (~10 lines/day) | None (catch-all) |
| `kyb-infra-cc-connect` | Go slog key=value | Medium (~200 lines/day) | `parse_slog` |
| `kyb-infra-clickhouse` | CK server logs | Low (~50 lines/day) | None (catch-all) |
| `kyb-infra-grafana` | Go slog key=value | Low (~20 lines/day) | `parse_slog` |
| `kyb-infra-kafka` | Kafka log format | Low (~30 lines/day) | `parse_generic` |
| `kyb-infra-postgresql-14/15/16/17` | PG stderr format | Medium (~500 lines/day each) | `parse_postgres` |
| `kyb-infra-redis` | Redis log format | Low (~10 lines/day) | `parse_generic` |
| `kyb-infra-sing-box` | JSON + plain text | High (~10K lines/day) | `parse_singbox` |
| `kyb-registry-cache` | Registry stdout | Low (~5 lines/day) | None (catch-all) |

**Excluded:**
- Vector's own logs (infinite loop prevention via `exclude` glob)
- Sandbox containers (ephemeral, not infra)
- User application containers

### 5.2 HTTP Source: Claude Hooks / Heartbeats (Optional)

In the future, the Claude hooks `emit-ck.sh` script and `boss_heartbeats` loop can POST to the Vector HTTP source instead of sending HTTP POST directly to ClickHouse. This gives them Vector's buffering and retry behavior.

**Hook endpoint:** `http://kyb-infra-vector:8282/hooks`

**Heartbeat endpoint:** `http://kyb-infra-vector:8282/heartbeats`

However, this is **not required** for the initial deployment. The existing hook and heartbeat scripts work and can be migrated later. The HTTP source is listed as optional for Phase 2.

### 5.3 Vector Source: Remote Cluster Forwarding (Central Only)

The central Vector listens on port 6000 for the `vector` protocol. Remote Vector instances connect to this address and stream their logs.

**Why `vector` protocol instead of Kafka:**
- Zero additional infrastructure (no Zookeeper/Redpanda)
- Built-in backpressure (if central is slow, remote buffers to disk)
- Same binary, same protocol
- Encryption via TLS if needed (Tailscale provides transport encryption already)

---

## 6. VRL Transform Catalog

### 6.1 `parse_docker_wrapper`

Unwraps Docker's json-file format. See config above.

### 6.2 `enrich_metadata`

Adds cluster, hostname, and ingestion timestamp to every event.

### 6.3 `route_by_container`

Maps container ID to container name. Vector 0.42+ supports enrichment tables. In the initial deployment, this is a best-effort mapping:

```coffeescript
# VRL enrichment table (inline for now)
container_names = {
  "cc-connect": "kyb-infra-cc-connect",
  "clickhouse": "kyb-infra-clickhouse",
  "grafana": "kyb-infra-grafana",
  "kafka": "kyb-infra-kafka",
  "postgresql-14": "kyb-infra-postgresql-14",
  "postgresql-15": "kyb-infra-postgresql-15",
  "postgresql-16": "kyb-infra-postgresql-16",
  "postgresql-17": "kyb-infra-postgresql-17",
  "redis": "kyb-infra-redis",
  "sing-box": "kyb-infra-sing-box",
  "registry": "kyb-registry-cache",
  "boss": "kyb-infra-boss"
}
```

In practice, the container ID is the only identifier in the file path. A more robust approach is to run `docker inspect` on startup and generate a static mapping file that Vector reads via the `file` source.

### 6.4 `parse_slog`

Parses Go `slog` key=value format used by cc-connect and Grafana.

**Input:**
```
time=2026-05-23T16:38:00.604Z level=INFO msg="turn complete" msg_id=om_xx tools=2 response_len=554 turn_duration=4h13m27.227059634s
```

**VRL handling:**
```coffeescript
pairs = parse_key_value!(.message, delimiter: " ", key_value_delimiter: "=")
.log_level = pairs.level
.log_msg = pairs.msg
```

**Duration parsing helper (VRL function):**
```coffeescript
# Go duration like "4h13m27.227059634s" → seconds as float
def parse_duration(dur) {
  total = 0.0
  h_match = match(dur, r'(\d+)h')
  m_match = match(dur, r'(?:h|^)(\d+)m')
  s_match = match(dur, r'(\d+(?:\.\d+)?)s')

  total = total + to_float!(h_match.groups[0]) * 3600.0 if h_match != null
  total = total + to_float!(m_match.groups[0]) * 60.0 if m_match != null
  total = total + to_float!(s_match.groups[0]) if s_match != null

  total
}
```

### 6.5 `parse_singbox`

Parses sing-box JSON log lines, including connection close events.

### 6.6 `parse_postgres`

Extracts PG log level, PID, and message from standard PG log lines.

### 6.7 `canonicalize`

The final transform that flattens all known fields into a canonical shape and stores the raw payload for forward compatibility:

```coffeescript
# Canonical fields (present on every row):
#   schema_version, source, event_type, event_time,
#   cluster, host, container_id, message, log_level
#
# Source-specific fields (extracted by upstream transforms):
#   msg_id, session, user, outbound_tag, etc.
.payload_raw = encode_json(.) ?? .message
```

---

## 7. Multi-Sink Routing

### 7.1 Sink: ClickHouse `infra.message_log` (Primary)

All canonicalized events land here. This is the primary observability table.

**Config:** See `vector.toml` above.

**Buffer:** Disk buffer, 256 MB max. If CK is unreachable for extended periods, Vector writes to disk. When CK recovers, Vector drains the buffer in order.

### 7.2 Sink: ClickHouse Source-Specific Tables (Future)

For specialized query performance, high-volume sources can route to dedicated tables:

| Source | Table | Reason |
|--------|-------|--------|
| cc-connect structured events | `cc.message_log` | High-value business metrics, dedicated dashboards |
| Sing-box connection close | `net.connection_log` | Traffic analysis, per-outbound aggregation |
| Docker events | `infra.docker_events` | Container lifecycle tracking |

These are **optional** and should only be added if query performance on `infra.message_log` degrades. The single-table approach is simpler and sufficient at current volume.

**Future routing config (when needed):**

```toml
[transforms.route_to_specialized]
type = "remap"
inputs = ["canonicalize"]
source = '''
  ._sink = if .source == "cc-connect" && .event_type == "structured_log" {
    "cc_message_log"
  } else if .source == "sing-box" && .event_type == "connection_close" {
    "net_connection_log"
  } else {
    "infra_message_log"
  }
'''

[sinks.clickhouse_cc]
type = "clickhouse"
inputs = ["route_to_specialized"]
# Only accepts events tagged for cc_message_log
# Uses VRL condition:
#   ._sink == "cc_message_log"
database = "cc"
table = "message_log"

[sinks.clickhouse_net]
type = "clickhouse"
inputs = ["route_to_specialized"]
database = "net"
table = "connection_log"
```

### 7.3 Sink: Vector Forward (Remote Clusters)

Remote Vector instances forward all logs to the central Vector. No per-pipeline filtering at this layer (ship everything, central decides routing).

### 7.4 Sink: File (Debug)

Writes all events as gzip-compressed JSON Lines to `/var/log/vector/debug.log`. Useful for:
- Debugging pipeline issues
- Replaying logs after schema changes
- Forensics after CK data loss

Retention: 7 days, managed by `logrotate` inside the Vector container.

---

## 8. ClickHouse Schema Consolidation

### 8.1 Canonical Table: `infra.message_log`

This single table replaces 5+ separate tables as the primary log store. It is optimized for the `(cluster, event_time)` query pattern that dominates observability queries.

```sql
CREATE DATABASE IF NOT EXISTS infra;

CREATE TABLE infra.message_log (
    -- Envelope (present on every row)
    schema_version  LowCardinality(String),    -- "1.0"
    source          LowCardinality(String),    -- "docker_logs", "cc-connect", "sing-box", "postgres", etc.
    event_type      LowCardinality(String),    -- "container_log", "structured_log", "connection_close", etc.
    event_time      DateTime64(3),             -- When the event occurred (source timestamp)

    -- Cluster identity (added by Vector enrichment)
    cluster         LowCardinality(String),    -- "mac-orbstack" | "aliyun" | "office"
    host            String,                    -- Hostname of the container
    container_id    String,                    -- Docker container SHA256 prefix (12 chars)

    -- Log content
    message         String,                    -- The actual log line
    stream          LowCardinality(String),    -- "stdout" | "stderr"
    log_level       LowCardinality(String),    -- "INFO", "ERROR", "WARN", etc. (parsed or empty)
    log_source      String,                    -- Container-specific source tag

    -- Structured fields (extracted by parser transforms)
    -- cc-connect / Go slog fields
    msg_id          String DEFAULT '',
    session         String DEFAULT '',
    user            String DEFAULT '',
    content_len     UInt32 DEFAULT 0,
    has_images      UInt8 DEFAULT 0,
    tools           UInt8 DEFAULT 0,
    response_len    UInt32 DEFAULT 0,
    turn_duration   Float64 DEFAULT 0,
    input_tokens    UInt32 DEFAULT 0,
    output_tokens   UInt32 DEFAULT 0,

    -- Sing-box fields
    outbound_tag    LowCardinality(String) DEFAULT '',
    network         LowCardinality(String) DEFAULT '',
    destination     String DEFAULT '',
    bytes_upload    UInt64 DEFAULT 0,
    bytes_download  UInt64 DEFAULT 0,
    duration_ms     UInt32 DEFAULT 0,
    rule_tag        LowCardinality(String) DEFAULT '',

    -- PostgreSQL fields
    pg_pid          UInt32 DEFAULT 0,

    -- Raw payload (for forward compatibility and debugging)
    payload_raw     String DEFAULT '',

    -- Ingestion metadata
    ingested_at     DateTime DEFAULT now()      -- When Vector wrote to CK
) ENGINE = MergeTree
ORDER BY (event_time, cluster, source)
TTL event_time + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

### 8.2 Existing Tables (Keep for Backward Compatibility)

The following tables are **NOT removed** during migration. They remain as query-friendly views of specific data. The Vector pipeline writes to BOTH the canonical table AND these specialized tables via separate sinks:

| Table | Purpose | Retention | After Migration |
|-------|---------|-----------|-----------------|
| `cc.message_log` | cc-connect structured events | 90 days | Kept, fed by Vector sink |
| `net.connection_log` | Sing-box connection closes | 30 days | Kept, fed by Vector sink |
| `infra.docker_events` | Container lifecycle | 90 days | Kept, fed by Vector sink |
| `kyb.claude_hook_events` | Claude hook events | 30 days | Unchanged (direct HTTP to CK) |
| `boss_heartbeats` | Boss heartbeat records | 90 days | Kept (direct HTTP to CK) |

**Unification plan (Phase 2+):**
1. New `infra.message_log` becomes the canonical source of truth
2. Specialized tables become MATERIALIZED VIEWs filtered from `infra.message_log`
3. Direct-write pipelines (hooks, heartbeats) optionally migrate to Vector HTTP source

### 8.3 Design Notes

- **Wide table with nullable fields**: The canonical table has columns for all known log types. Defaults are `''` or `0` rather than `NULL` to avoid NULL handling complexity in ClickHouse. This is acceptable because the table is sparse -- most rows have only a handful of non-default fields.

- **LowCardinality on cluster, source, event_type, stream, log_level**: These columns have < 20 distinct values each. LowCardinality reduces storage ~8x and speeds up GROUP BY queries.

- **TTL 90 days**: Consistent with existing tables. Event volume is low enough that 90 days of all events combined is < 1 GB compressed.

- **Sort key (event_time, cluster, source)**: Covers 90%+ of queries: time range across clusters, per-cluster filtering, per-source breakdown.

---

## 9. Directory & File Layout

All Vector-related files live in the kyb repo under a single directory:

```
docs/infra/vector/
├── vector.toml              # Main config (shared across all clusters)
├── central.toml             # Central-only override (vector source listener)
├── scripts/
│   ├── deploy-central.sh    # Deploy Vector on Mac/Orbstack
│   ├── deploy-remote.sh     # Deploy Vector on Aliyun/Office
│   ├── reload-config.sh     # SIGHUP reload on a running instance
│   └── verify-pipeline.sh   # End-to-end verification
├── schemas/
│   ├── infra.message_log.sql    # Canonical table DDL
│   └── 00-create-databases.sql  # Database creation
└── README.md                # Quick reference (not a full doc — this document is the reference)
```

This layout is referenced in this design doc. The actual files are created during implementation.

---

## 10. Operational Playbook

### 10.1 Deployment

**Step 1: Create the CK table** (one-time, on central CK):

```bash
# From Mac/Orbstack:
clickhouse-client --host host.orb.internal --query "$(cat docs/infra/vector/schemas/infra.message_log.sql)"
```

**Step 2: Deploy Vector on central cluster (Mac/Orbstack):**

```bash
# Create data volume
docker volume create vector-data

# Deploy (from kyb repo root)
docker run -d \
  --name kyb-infra-vector \
  --restart unless-stopped \
  --network kyb-infra \
  -p 100.104.244.99:6000:6000 \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v vector-data:/var/lib/vector \
  -v $(pwd)/docs/infra/vector:/etc/vector:ro \
  -e VECTOR_CLUSTER_NAME=mac-orbstack \
  -e VECTOR_CLUSTER_ROLE=central \
  -e VECTOR_CK_ENDPOINT=http://host.orb.internal:8123 \
  -e VECTOR_SELF_ADDR=0.0.0.0:6000 \
  --init \
  timberio/vector:0.42.0-alpine \
  --config /etc/vector/vector.toml --config /etc/vector/central.toml
```

**Step 3: Verify central Vector is collecting:**

```bash
# Check container logs
docker logs kyb-infra-vector --tail 20

# Check Vector internal metrics
curl -s http://localhost:8686/metrics | grep -E "vector_events_in_total|vector_sink_events_total"

# Check CK for data
clickhouse-client --host host.orb.internal \
  --query "SELECT count() FROM infra.message_log WHERE event_time > now() - INTERVAL 5 MINUTE"
```

**Step 4: Deploy on remote clusters:**

```bash
# Aliyun (via SSH dispatch):
ssh sim "docker volume create vector-data && \
  docker run -d --name kyb-infra-vector --restart unless-stopped \
    --network kyb-infra \
    -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
    -v vector-data:/var/lib/vector \
    -v /home/dev/projects/kyb/docs/infra/vector:/etc/vector:ro \
    -e VECTOR_CLUSTER_NAME=aliyun \
    -e VECTOR_CLUSTER_ROLE=remote \
    -e VECTOR_CENTRAL_ADDR=100.104.244.99:6000 \
    --init \
    timberio/vector:0.42.0-alpine \
    --config /etc/vector/vector.toml"

# Office (nuc8):
ssh nuc8 "docker volume create vector-data && \
  docker run -d --name kyb-infra-vector --restart unless-stopped \
    --network kyb-infra \
    -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
    -v vector-data:/var/lib/vector \
    -v /home/dev/projects/kyb/docs/infra/vector:/etc/vector:ro \
    -e VECTOR_CLUSTER_NAME=office \
    -e VECTOR_CLUSTER_ROLE=remote \
    -e VECTOR_CENTRAL_ADDR=100.104.244.99:6000 \
    --init \
    timberio/vector:0.42.0-alpine \
    --config /etc/vector/vector.toml"
```

**Step 5: Verify end-to-end multi-cluster:**

```sql
-- Should see events from all three clusters
SELECT cluster, count() AS events
FROM infra.message_log
WHERE event_time > now() - INTERVAL 10 MINUTE
GROUP BY cluster
ORDER BY events DESC;
```

### 10.2 Daily Operations

**Check Vector health:**

```bash
# Health endpoint
curl -s http://localhost:8686/health

# Component topology
docker exec kyb-infra-vector vector top

# Buffer usage
docker exec kyb-infra-vector du -sh /var/lib/vector/
```

**Check ClickHouse ingestion rate:**

```sql
SELECT
    toStartOfHour(event_time) AS hour,
    cluster,
    source,
    count() AS events
FROM infra.message_log
WHERE event_time > now() - INTERVAL 24 HOUR
GROUP BY hour, cluster, source
ORDER BY hour DESC, cluster;
```

**Check for pipeline lag:**

```sql
SELECT
    cluster,
    max(now() - toUnixTimestamp(event_time)) AS max_lag_seconds,
    count() AS events_in_last_minute
FROM infra.message_log
WHERE event_time > now() - INTERVAL 1 MINUTE
GROUP BY cluster;
```

**Restart Vector (rarely needed, use SIGHUP reload):**

```bash
docker restart kyb-infra-vector
```

### 10.3 Troubleshooting

| Symptom | Likely Cause | Check | Fix |
|---------|------------|-------|-----|
| No data in CK from any cluster | Vector not started | `docker ps`, `docker logs kyb-infra-vector` | Restart container |
| No data from remote cluster | Network issue | `ping 100.104.244.99` from remote | Check Tailscale connectivity |
| Only some containers visible | File source path issue | Check Vector logs for file errors | Verify `/var/lib/docker/containers` mount |
| Events in CK but no structured fields | Parser not matching | Check `message` + `payload_raw` | Tweak VRL regex |
| Buffer growing unbounded | CK unreachable | `clickhouse-client --query "SELECT 1"` | Restart CK; Vector drains automatically |
| "Failed to connect to CK" on startup | CK not ready | `curl http://host.orb.internal:8123` | Start CK first, Vector retries |
| High disk usage from buffer | CK down for extended period | `du -sh /var/lib/vector/` | Increase buffer max_size or fix CK |
| Vector OOM-killed | Memory limit too low | `docker inspect kyb-infra-vector` | Add `--memory=256m` to docker run |

### 10.4 Alert Rules

| Rule | Condition | Severity | Action |
|------|-----------|----------|--------|
| Pipeline stopped | `infra.message_log` has 0 events in 5 min for any cluster | P1 | Restart Vector on the affected cluster |
| Remote disconnected | No events from a remote cluster in 10 min | P1 | Check Tailscale + SSH into remote |
| Buffer filling | Vector buffer > 100 MB | P2 | Check CK availability |
| Parse error rate high | `payload_raw` stored more often than structured | P3 | Tweak parser config |
| CK write errors | Vector logs show CK write failures | P2 | Check CK health |

---

## 11. Migration Strategy

### 11.1 Phase 0: Deploy Vector (Current)

Deploy the unified Vector container alongside existing pipelines. **No existing pipeline is modified.** This is zero-risk:

1. Create `infra.message_log` table in CK
2. Deploy Vector on Mac/Orbstack (central)
3. Verify data flowing into `infra.message_log`
4. Deploy Vector on Aliyun and Office (remote)
5. Verify multi-cluster forwarding

**During Phase 0:**
- cc-connect → (nothing changed, still goes nowhere)
- Claude hooks → emit-ck.sh → CK (unchanged)
- Boss heartbeats → shell loop → CK (unchanged)
- Docker events → not deployed yet
- Sing-box metrics → not deployed yet

### 11.2 Phase 1: Dual-Write for cc-connect

Deploy Vector as the cc-connect log shipper alongside the existing (empty) pipeline:

```toml
[sinks.clickhouse_cc]
type = "clickhouse"
inputs = ["canonicalize"]
# Only send cc-connect structured events to cc.message_log
# (This requires a conditional route)
database = "cc"
table = "message_log"
```

**During Phase 1:**
- `infra.message_log` has ALL logs (including cc-connect)
- `cc.message_log` has cc-connect structured events only (dual-written)
- Grafana dashboards point to `cc.message_log` as before
- New queries on `infra.message_log` have access to ALL logs

### 11.3 Phase 2: Migrate Claude Hooks to Vector HTTP

Optional optimization. Replace the shell script HTTP POST to CK with an HTTP POST to Vector:

**Current:**
```
Claude hook → emit-ck.sh → HTTP POST → CK (fire-and-forget)
```

**After:**
```
Claude hook → emit-ck-v2.sh → HTTP POST → Vector :8282 → Vector buffer → CK
```

Benefits:
- Vector's disk buffer absorbs CK downtime (hooks never lose events)
- Vector enriches the event with cluster/host metadata
- Single point of CK write (easier to monitor and throttle)

### 11.4 Phase 3: Migrate Heartbeats to Vector HTTP

Same pattern as Claude hooks.

### 11.5 Phase 4: Deprecate Bespoke Pipelines

Once all sources route through Vector:
1. Remove direct HTTP POST scripts (emit-ck.sh, heartbeat loop)
2. Remove Fluentd configs (if deployed)
3. Remove Kafka topics (if deployed)
4. Keep dedicated CK tables as MATERIALIZED VIEWs from `infra.message_log`

**Final state:**
```
Every container → Vector → infra.message_log (canonical)
                                    ├── cc.message_log (MV filtered on source='cc-connect')
                                    ├── net.connection_log (MV filtered on source='sing-box')
                                    ├── infra.docker_events (MV filtered on event_type='docker_event')
                                    └── boss_heartbeats (native table, HTTP source)
```

---

## 12. Resource Estimates

### 12.1 Storage (ClickHouse, `infra.message_log`)

| Source | Events/day | Row size (compressed) | Daily volume | 90-day total |
|--------|-----------|----------------------|-------------|-------------|
| Container logs (all infra) | ~5,000 | ~200 B | ~1 MB | ~90 MB |
| cc-connect structured | ~200 | ~350 B | ~70 KB | ~6 MB |
| Sing-box connection closes | ~10,000 | ~250 B | ~2.5 MB | ~225 MB |
| PG logs | ~2,000 | ~150 B | ~300 KB | ~27 MB |
| All other (Grafana, Kafka, Redis, etc.) | ~500 | ~100 B | ~50 KB | ~4.5 MB |
| **Total** | **~17,700** | | **~3.9 MB** | **~352 MB** |

ClickHouse columnar compression (LZ4 + LowCardinality) reduces this by 5-8x: **~45-70 MB for 90 days**.

### 12.2 Vector Resource Usage

| Resource | Per instance (estimate) |
|----------|------------------------|
| CPU | < 0.1 core (at < 20K events/day) |
| Memory | ~10-25 MB RSS (idle), ~30-50 MB (peak) |
| Disk (buffers) | ~10-50 MB (normal), up to 256 MB (max) |
| Network (central) | ~1 KB/s average, ~10 KB/s peak |
| Network (remote) | ~1 KB/s (forward to central) |

### 12.3 Comparison with Current Fragmentation

| Resource | Current (bespoke) | Unified Vector | Savings |
|----------|------------------|----------------|---------|
| Containers running | 0 (Vector not deployed) + 1 Fluentd (speculative) + 1 Kafka (speculative) | 1 Vector | -2 containers |
| Config files | 6+ design docs with config snippets | 1 canonical TOML file | -5 files |
| Buffer capacity | 0 (all fire-and-forget) | 256 MB disk | +256 MB reliability |
| Parser maintenance | 4+ regex patterns in different languages (shell, Ruby, Python) | 1 VRL transform chain | Unified language |

---

## 13. Failure Modes

| Failure | Effect | Recovery |
|---------|--------|----------|
| **Vector process crashes** | Log collection stops. Events accumulate in Docker json-log files on disk. Position file persists. | Docker restart policy (`--restart unless-stopped`) restarts Vector. File tail resumes from last position. Events generated during downtime are NOT lost -- the file still contains them. |
| **Vector OOM-killed** | Same as crash. | Add `--memory=256m` limit; increase Docker memory for the container. |
| **CK unreachable** | Vector buffers events to disk (up to 256 MB). Events are NOT written to CK. | When CK recovers, Vector drains the buffer in order. At current volume, 256 MB = ~60 days of buffer capacity. |
| **CK permanently lost** | All buffered events in Vector are safe (disk buffer). Events already in CK are lost. | Reload data from debug file sink if enabled. Otherwise, data from last checkpoint to failure is irrecoverable. |
| **Disk full (Vector buffer)** | Vector blocks writes (when_full = "block"). New events are NOT accepted. | Free disk space. Vector resumes. The backlog of file-tail events will catch up. |
| **Remote Vector cannot reach central** | Remote Vector buffers to disk. Events are NOT forwarded. | When connectivity resumes, buffer drains in order. Tailscale mesh automatically recovers. |
| **Central Vector port 6000 unreachable** | Remote clusters buffer to disk. | Same as above. |
| **Config reload fails** | Vector continues with old config. SIGHUP error is logged. | Fix the config file error and re-send SIGHUP. |
| **Docker json-log file rotation** | Docker compresses/deletes old log files. Vector's file source detects rotation via inode watch. | Vector automatically follows the new file. Position is maintained. |
| **Container restarts with new ID** | Log file path changes (new container ID). | Vector's file source will pick up the new glob match. The old file is no longer written to; Vector closes it. |

---

## Appendix A: Quick-Start Commands

```bash
# 1. Create CK table
clickhouse-client --host host.orb.internal \
  --query "$(cat docs/infra/vector/schemas/infra.message_log.sql)"

# 2. Deploy central Vector
bash docs/infra/vector/scripts/deploy-central.sh

# 3. Deploy remote Vector (on each remote)
bash docs/infra/vector/scripts/deploy-remote.sh aliyun
bash docs/infra/vector/scripts/deploy-remote.sh office

# 4. Verify
docker exec kyb-infra-vector vector top
clickhouse-client --host host.orb.internal \
  --query "SELECT cluster, count() FROM infra.message_log WHERE event_time > now() - INTERVAL 10 MINUTE GROUP BY cluster"

# 5. Reload config after edit
bash docs/infra/vector/scripts/reload-config.sh
```

## Appendix B: Reference to Existing Docs

This design consolidates and replaces the log-collection portions of:

| Existing Document | Status After Migration |
|-------------------|----------------------|
| `docs/infra/designs/bridge-ck-ingestion.md` | Superseded by unified vector.toml |
| `docs/infra/designs/bridge-metrics-logging.md` | Kept (defines metrics, not transport) |
| `docs/infra/designs/bridge-hooks-alerting.md` | Kept (defines alert rules, not transport) |
| `docs/infra/reviews/sing-box-metrics.md` | Superseded (Vector config absorbed) |
| `docs/infra/reviews/docker-events.md` | Kept (defines event types and alerts) |
| `docs/infra/reviews/kafka-message-bus.md` | Superseded (Vector replaces Kafka as buffer) |
| `docs/infra/reviews/fluentd-pipeline.md` | Superseded (Vector replaces Fluentd) |
| `docs/infra/reviews/otel-patrol.md` | Kept (Vector file_source stays, trace model unchanged) |
| `docs/infra/handbook/hooks-ck-pipeline.md` | Kept (hook script unchanged until Phase 2) |

---

> **Summary:** A single Vector instance per cluster collects logs from ALL infra containers via file tail, enriches with cluster metadata, parses structured formats (Go slog, JSON, PostgreSQL, etc.), and writes to a canonical `infra.message_log` table in ClickHouse. Remote clusters forward to central over Tailscale. This replaces 10+ bespoke pipelines with one config file, one container, and one VRL transform chain. Zero-risk migration: deploy alongside existing pipelines, then migrate gradually.

> /人◕ ‿‿ ◕人＼
