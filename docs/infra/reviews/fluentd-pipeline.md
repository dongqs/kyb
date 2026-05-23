---
decision: 不应该做
---

# Fluentd Log Collector for Infra Containers

**Status:** Design Comparison & Pipeline Reference
**Date:** 2026-05-23
**Context:** Evaluating Fluentd as a replacement/alternative to Vector for collecting Docker container logs from the multi-cluster infra fleet (Mac/Orbstack, Aliyun sim, Office nuc8).

---

## Table of Contents

1. [Background](#1-background)
2. [Pipeline Architecture](#2-pipeline-architecture)
3. [Config Reference](#3-config-reference)
4. [Parser Reference](#4-parser-reference)
5. [Sink Reference](#5-sink-reference)
6. [Fluentd vs Vector](#6-fluentd-vs-vector)
7. [Deployment](#7-deployment)
8. [Verification](#8-verification)

---

## 1. Background

### 1.1 Current State

All infra containers use Docker's `json-file` log driver. The current log collection landscape:

| Service | Collector | Sink | Log Format |
|---------|-----------|------|------------|
| cc-connect | Planned: Vector | ClickHouse | Go `slog` key=value (not JSON) |
| Claude hooks | Direct HTTP POST | ClickHouse | JSON (hook events) |
| Boss heartbeats | Shell loop HTTP POST | ClickHouse | JSON |
| All other containers | None (manual `docker logs`) | None | Container stdout/stderr |

Gaps:
- No centralized log collection for most infra containers (PG, Redis, Kafka, Grafana, sing-box, registry cache)
- No log rotation management outside Docker's built-in json-file
- No structured parsing for non-cc-connect containers
- No multi-cluster log forwarding

### 1.2 Why Fluentd Now

Fluentd (v1.16+) offers:
- **Mature Docker log driver integration** -- native `@type tail` with Docker json-file format
- **ClickHouse sink** -- `fluent-plugin-clickhouse` (community, maintained)
- **Multi-cluster forwarding** -- `@type forward` for inter-cluster log aggregation
- **Rich parser ecosystem** -- regex, multiline, k8s, syslog, Apache, nginx parsers built in
- **Buffer/retry** -- file-based buffering with exponential backoff (Vector requires disk buffer config separately)
- **Lightweight** -- ~80 MB container image (Ruby runtime), comparable to Vector's ~50 MB Rust binary

---

## 2. Pipeline Architecture

### 2.1 Single-Cluster Pipeline

```
Docker json-file logs (/var/lib/docker/containers/*/*-json.log)
    │
    ▼
Fluentd agent (per-host or per-boss)
    │  tail input with regex parsers
    │  buffer to disk or memory
    ▼
Sinks (per log type):
    ├── ClickHouse (structured logs: cc-connect, heartbeats, errors)
    ├── Forward (to central cluster for aggregation)
    └── File (fallback / debug)
```

### 2.2 Multi-Cluster Architecture

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│ Aliyun (sim)        │     │ Office (nuc8)        │     │ Mac/Orbstack        │
│                     │     │                      │     │ (Central)           │
│ Fluentd agent       │     │ Fluentd agent        │     │                     │
│   ├─ tail: PG       │     │   ├─ tail: Nexus     │     │ Fluentd aggregator  │
│   ├─ tail: ACR      │     │   ├─ tail: proxy     │     │   ├─ ClickHouse     │
│   ├─ tail: runners  │     │   ├─ tail: GitLab    │     │   ├─ Grafana       │
│   └─ forward: ck    │     │   └─ forward: ck     │     │   └─ File archive   │
│         │           │     │         │            │     │         │           │
│         └───────────┼─────┼─────────┼────────────┼─────┼─────────┘           │
│                     │     │                      │     │                     │
│                     │     │                      │     │ Fluentd agent       │
│                     │     │                      │     │   ├─ tail: PG fleet │
│                     │     │                      │     │   ├─ tail: Kafka    │
│                     │     │                      │     │   ├─ tail: Redis    │
│                     │     │                      │     │   ├─ tail: Grafana  │
│                     │     │                      │     │   ├─ tail: sing-box │
│                     │     │                      │     │   ├─ tail: cc-conn  │
│                     │     │                      │     │   ├─ tail: boss*    │
│                     │     │                      │     │   └─ tail: registry │
│                     │     │                      │     └──── ClickHouse      │
└─────────────────────┘     └─────────────────────┘                            │
                                                                               │
  Forward(secure) ───────── Tailscale mesh ────────────────────────────────────┘
```

**Design decisions:**
- **Per-host agent** on remote clusters (Aliyun, Office) sends structured logs to central cluster via `forward` over Tailscale.
- **Central aggregator** on Mac/Orbstack receives all remote logs and writes to ClickHouse.
- **Local logs** on Mac/Orbstack go directly to ClickHouse (no forward hop).
- **Fail-open**: if central CK is unreachable, Fluentd buffers to disk and retries.

### 2.3 Log Type Routing

```
                      ┌─────────────────────────────┐
                      │  Fluentd: tail Docker logs   │
                      │  /var/lib/docker/containers/ │
                      │  */*-json.log                │
                      └─────────────┬───────────────┘
                                    │
                        ┌───────────┴───────────┐
                        │   tag routing         │
                        │   (container name)    │
                        └───────┬───────────────┘
                                │
          ┌─────────────────────┼─────────────────────┐
          ▼                     ▼                     ▼
   cc-connect.*           postgresql.*           kafka.*
          │                     │                     │
    ┌─────┴─────┐         ┌────┴────┐           ┌────┴────┐
    │ slog kv   │         │ skip    │           │ skip    │
    │ parser    │         │(PG logs │           │(Kafka   │
    │ → record  │         │ noisy,  │           │ logs    │
    └─────┬─────┘         │ not yet)│           │ not yet)│
          │               └─────────┘           └─────────┘
          ▼
    ┌─────────────┐
    │ ClickHouse  │
    │ cc.message  │
    │ _log        │
    └─────────────┘

          sing-box.*          grafana.*            boss.*
          │                     │                     │
    ┌─────┴─────┐         ┌────┴────┐           ┌────┴────┐
    │ syslog    │         │ json    │           │ skip    │
    │ parser    │         │ parser  │           │(boss    │
    └─────┬─────┘         └────┬────┘           │ heart-  │
          │                    │                 │ beats   │
          ▼                    ▼                 │ already │
    ┌──────────┐         ┌──────────┐            │ via CK  │
    │ File     │         │ File     │            │ HTTP)   │
    │(debug)   │         │(debug)   │            └─────────┘
    └──────────┘         └──────────┘
```

---

## 3. Config Reference

### 3.1 Base Fluentd Config (`fluentd.conf`)

```
# ──────────────────────────────────────────────
# Fluentd Base Config — infra log collector
# ──────────────────────────────────────────────

<system>
  log_level          info
  emit_error_log_interval 60
  suppress_repeated_stacktrace true
</system>

# ──────── Source: All Docker json-file logs ────────
<source>
  @type tail
  @id docker_json_file
  path /var/lib/docker/containers/*/*-json.log
  exclude_path ["/var/lib/docker/containers/*-json.log"]
  pos_file /var/log/fluentd/docker.pos
  tag docker.*
  read_from_head false

  <parse>
    @type json
    time_key time
    time_format %Y-%m-%dT%H:%M:%S.%N%z
    keep_time_key false
  </parse>
</source>

# ──────── Filter: Extract container name from tag ────────
<filter docker.**>
  @type record_transformer
  <record>
    container_name ${tag_parts[1]}
    cluster "#{ENV['FLUENT_CLUSTER'] || 'unknown'}"
    hostname "#{Socket.gethostname}"
  </record>
</filter>
```

### 3.2 cc-connect Parser Config

cc-connect outputs Go `slog` key=value format, not JSON. Fluentd's `regexp` parser extracts the fields.

```
# ──────── Match: cc-connect logs ────────
<match docker.kyb-infra-cc-connect>
  @type relabel
  @label @CC_CONNECT
</match>

<label @CC_CONNECT>
  # Parse Go slog key=value format
  <filter>
    @type parser
    key_name message
    reserve_data true

    <parse>
      @type regexp
      expression /^time=(?<time>\S+) level=(?<level>\S+) msg="(?<msg>[^"]*)"(?<kv>\s+\S+=\S+)*$/
    </parse>
  </filter>

  # Second pass: extract key=value pairs from the remaining string
  <filter>
    @type parser
    key_name kv
    reserve_data true
    hash_value_field parsed_kv

    <parse>
      @type key_value
      delimiter " "
      kv_delimiter "="
    </parse>
  </filter>

  # Flatten kv pairs into top-level record
  <filter>
    @type record_transformer
    enable_ruby true
    renew_record false

    <record>
      event_time ${record["time"]}
      level       ${record["level"]}
      event_type  ${record["msg"]}
      msg_id      ${record["parsed_kv"]["msg_id"]}
      session     ${record["parsed_kv"]["session"]}
      user        ${record["parsed_kv"]["user"]}
      content_len ${record["parsed_kv"]["content_len"]}
      has_images  ${record["parsed_kv"]["has_images"]}
      has_audio   ${record["parsed_kv"]["has_audio"]}
      has_files   ${record["parsed_kv"]["has_files"]}
      agent_session ${record["parsed_kv"]["agent_session"]}
      tools       ${record["parsed_kv"]["tools"]}
      response_len  ${record["parsed_kv"]["response_len"]}
      turn_duration ${record["parsed_kv"]["turn_duration"]}
      input_tokens  ${record["parsed_kv"]["input_tokens"]}
      output_tokens ${record["parsed_kv"]["output_tokens"]}
    </record>
  </filter>

  # Convert turn_duration Go duration → seconds
  <filter>
    @type record_transformer
    enable_ruby true
    <record>
      turn_duration_seconds ${record["turn_duration"] ? parse_duration(record["turn_duration"]) : nil}
    </record>
  </filter>

  # ClickHouse sink
  <match **>
    @type relabel
    @label @CLICKHOUSE
  </match>
</label>
```

### 3.3 Go Duration Parser (Ruby helper)

Fluentd supports Ruby plugins inline. For `turn_duration`, we need to convert Go duration strings like `4h13m27.227059634s` to Float64 seconds.

```
# Place in /etc/fluentd/plugin/parse_duration.rb
module Fluent
  module Helpers
    def parse_duration(dur)
      return nil if dur.nil? || dur.empty?
      total = 0.0
      # Match Go duration format: 4h13m27.227059634s
      if dur =~ /(?:(\d+)h)?(?:(\d+)m)?(\d+(?:\.\d+)?)s/
        total += $1.to_f * 3600 if $1
        total += $2.to_f * 60   if $2
        total += $3.to_f
      end
      total
    end
  end
end
```

### 3.4 ClickHouse Sink Config

Fluentd writes structured records to ClickHouse using `fluent-plugin-clickhouse`:

```
# ──────── ClickHouse Output ────────
<label @CLICKHOUSE>
  <match **>
    @type clickhouse
    @id clickhouse_sink

    # Connection
    clickhouse_host    "#{ENV['CLICKHOUSE_HOST'] || 'host.orb.internal'}"
    clickhouse_port    8123
    clickhouse_database "cc"

    # Table and format
    table message_log
    format JSONEachRow

    # Buffer to disk (safety net)
    <buffer>
      @type file
      path /var/log/fluentd/buffer/clickhouse
      flush_mode interval
      flush_interval 5
      retry_max_interval 60
      retry_forever true
      chunk_limit_size 1MB
      total_limit_size 100MB
    </buffer>

    # Connection pool
    <server>
      host "#{ENV['CLICKHOUSE_HOST'] || 'host.orb.internal'}"
      port 8123
    </server>
  </match>
</label>
```

### 3.5 Docker Compose Deployment

```yaml
# docker-compose.fluentd.yml
version: '3.8'

services:
  fluentd:
    image: fluent/fluentd:v1.18-debian-1
    container_name: kyb-infra-fluentd
    restart: unless-stopped
    volumes:
      # Fluentd config
      - ./fluentd/conf:/fluentd/etc
      # Docker logs (read-only)
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      # Position file (persist across restarts)
      - fluentd-pos:/var/log/fluentd
      # Buffer (persist across restarts)
      - fluentd-buffer:/fluentd/buffer
    environment:
      - FLUENT_CLUSTER=mac-orbstack
      - CLICKHOUSE_HOST=host.orb.internal
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: 3
    # Use host network to simplify DNS resolution for CK
    network_mode: host

volumes:
  fluentd-pos:
  fluentd-buffer:
```

**Mount explanation:**

| Mount | Why |
|-------|-----|
| `/var/lib/docker/containers:ro` | Read Docker json-log files |
| `fluentd-pos` | Position file survives container restart |
| `fluentd-buffer` | Disk buffer survives container crash |

### 3.6 Multi-Cluster Forward Config

**On remote cluster agents (Aliyun, Office):**

```
# ──────── Forward to central ClickHouse ────────
<match **>
  @type forward
  @id forward_to_central

  <server>
    host 100.104.244.99          # Central cluster (Mac/Orbstack)
    port 24224
    weight 60
  </server>

  <server>
    host 100.104.244.99          # Fallback port
    port 24225
    weight 40
  </server>

  # Require ack response for reliable delivery
  require_ack_response true

  # Buffer
  <buffer>
    @type file
    path /var/log/fluentd/buffer/forward
    flush_interval 2
    retry_max_interval 120
    retry_forever true
    chunk_limit_size 512KB
    total_limit_size 50MB
  </buffer>

  # Over Tailscale, use shared_key for auth
  <security>
    self_hostname "#{Socket.gethostname}"
    shared_key "#{ENV['FLUENT_FORWARD_KEY']}"
  </security>
</match>
```

**On central aggregator (Mac/Orbstack):**

```
# ──────── Receive from remote clusters ────────
<source>
  @type forward
  @id forward_input

  port 24224
  bind 0.0.0.0

  <security>
    self_hostname "central-fluentd"
    shared_key "#{ENV['FLUENT_FORWARD_KEY']}"
  </security>
</source>

<source>
  @type forward
  @id forward_input_fallback
  port 24225
  bind 0.0.0.0

  <security>
    self_hostname "central-fluentd-fallback"
    shared_key "#{ENV['FLUENT_FORWARD_KEY']}"
  </security>
</source>

# Tag incoming remote logs with source cluster
<filter **>
  @type record_transformer
  <record>
    forwarded_from ${tag}
  </record>
</filter>
```

---

## 4. Parser Reference

### 4.1 Docker json-file (Default)

Docker's `json-file` driver writes each line as:

```json
{"log":"actual log line\n","stream":"stdout","time":"2026-05-23T16:38:00.604Z"}
```

Fluentd's built-in `json` parser handles this natively. The `log` field contains the actual output. The `stream` field distinguishes stdout vs stderr.

**Config:**
```
<parse>
  @type json
  time_key time
  time_format %Y-%m-%dT%H:%M:%S.%N%z
</parse>
```

### 4.2 Go slog Key=Value Format (cc-connect)

**Input:**
```
time=2026-05-23T16:38:00.604Z level=INFO msg="turn complete" session=s1 agent_session=d2720c67-... msg_id=om_x... tools=2 response_len=554 turn_duration=4h13m27.227059634s input_tokens=431 output_tokens=521
```

**Fluentd regex parser:**
```
<parse>
  @type regexp
  expression /^time=(?<time>\S+) level=(?<level>\S+) msg="(?<msg>[^"]*)"(?:\s+(?<kv>\S+=\S+(?: \S+=\S+)*))?$/
</parse>
```

**Alternative: multiline-aware regex** (handles msg with embedded quotes):
```
<parse>
  @type regexp
  expression /^time=(?<time>[^\s]+) level=(?<level>[^\s]+) msg="(?<msg>(?:[^"\\]|\\.)*)"(?:\s+(?<rest>.*))?$/
</parse>
```

**Fields extracted:**

| Field | Regex group | Post-process |
|-------|-------------|-------------|
| `time` | `(?<time>\S+)` | Parsed as event_time |
| `level` | `(?<level>\S+)` | Direct |
| `msg` | `(?<msg>[^"]*)` | Mapped to event_type |
| `msg_id` | From kv pairs | key_value parser |
| `session` | From kv pairs | key_value parser |
| `turn_duration` | From kv pairs | Go duration → seconds |
| All others | From kv pairs | Direct |

### 4.3 PostgreSQL Logs

PG logs `stderr` with a timestamp prefix:

```
2026-05-23 16:38:00.604 CST [12345] LOG:  checkpoint starting: time
2026-05-23 16:38:01.123 CST [12346] ERROR:  relation "foo" does not exist at character 22
```

**Fluentd parser (if collection is needed):**
```
<parse>
  @type regexp
  expression /^(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \w+) \[(?<pid>\d+)\] (?<level>\w+):\s+(?<message>.*)$/
  time_format %Y-%m-%d %H:%M:%S.%N %Z
</parse>
```

**Note:** PG logs are verbose. Currently not collected by Vector either. Consider collecting only ERROR/PANIC level via `grep` filter.

### 4.4 Redis Logs

Redis logs to stdout with a simple timestamp:

```
1:C 23 May 2026 16:38:00.604 # Redis 7.0.15 starting
1:M 23 May 2026 16:38:00.608 * Ready to accept connections tcp
```

**Fluentd parser:**
```
<parse>
  @type regexp
  expression /^(?<pid>\d+):(?<role>\w)\s+(?<timestamp>\d{1,2} \w+ \d{4} \d{2}:\d{2}:\d{2}\.\d{3})\s+(?<level>[#\*\.-])\s+(?<message>.*)$/
  time_format %d %b %Y %H:%M:%S.%N
</parse>
```

### 4.5 Kafka Logs

Kafka logs to stdout in a structured format with logger name:

```
[2026-05-23 16:38:00,604] INFO [KafkaServer id=0] Started (kafka.server.KafkaServer)
```

**Fluentd parser:**
```
<parse>
  @type regexp
  expression /^\[(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\]\s+(?<level>\w+)\s+\[(?<component>[^\]]+)\]\s+(?<message>.*) \((?<logger>[^\)]+)\)$/
  time_format %Y-%m-%d %H:%M:%S,%N
</parse>
```

### 4.6 Grafana Logs

Grafana logs to stdout in a structured format:

```
logger=sqlstore t=2026-05-23T16:38:00.604+08:00 level=info msg="Migration log" logger=sqlstore.migrations
```

This is also Go `slog` key=value format, same parser as cc-connect (Section 4.2).

### 4.7 Sing-Box Logs

Sing-box logs to stdout in a structured JSON format:

```json
{"level":"info","time":"2026-05-23T16:38:00.604+08:00","message":"inbound/redir: started"}
```

Handled by the default Docker json-file JSON parser, with additional `level` and `message` fields extracted automatically.

---

## 5. Sink Reference

### 5.1 ClickHouse Sink (`fluent-plugin-clickhouse`)

**Install:**
```bash
# In Dockerfile or custom image
gem install fluent-plugin-clickhouse --no-document
```

**Config options:**

| Option | Default | Description |
|--------|---------|-------------|
| `clickhouse_host` | localhost | CK host |
| `clickhouse_port` | 8123 | HTTP port |
| `clickhouse_database` | default | Database name |
| `table` | (required) | Target table |
| `format` | JSONEachRow | Write format |
| `buffer_type` | file | Buffer backend |
| `flush_interval` | 5s | Batch flush interval |

**Error handling:**
- CK unreachable → buffer accumulates on disk, retries with exponential backoff
- Schema mismatch → Fluentd logs error, drops record
- All errors are logged at `warn` level to avoid filling info logs

### 5.2 Forward Sink (`@type forward`)

For inter-cluster log shipping over Tailscale.

**Config options:**

| Option | Default | Description |
|--------|---------|-------------|
| `port` | 24224 | Listening port |
| `bind` | 0.0.0.0 | Bind address |
| `source_host` | (auto) | Client hostname |
| `require_ack_response` | true | Wait for ack |
| `shared_key` | (required) | Auth key |

**Security considerations:**
- Run over Tailscale mesh (encrypted WireGuard tunnel)
- `shared_key` authentication prevents unauthorized sends
- Bind only to Tailscale interface if possible: `bind 100.x.y.z`

### 5.3 File Sink (`@type file`)

Fallback and debug output.

```config
<match debug.**>
  @type file
  path /var/log/fluentd/debug
  append true
  <buffer>
    @type file
    path /var/log/fluentd/buffer/debug
  </buffer>
</match>
```

**Use cases:**
- Temporary debug capture of verbatim logs
- Fallback when ClickHouse is unavailable (before buffer overflows)
- Archival of raw logs for later replay

### 5.4 Stdout Sink (`@type stdout`)

Human-readable output for `docker logs` inspection.

```config
<match stdout.**>
  @type stdout
</match>
```

---

## 6. Fluentd vs Vector

### 6.1 Detailed Comparison

| Criteria | Fluentd (v1.18) | Vector (v0.42) | Winner |
|----------|----------------|----------------|--------|
| **Language** | Ruby + C (native plugins) | Rust | Vector (performance) |
| **Container image** | ~80 MB (debian-based) | ~50 MB (distroless) | Vector |
| **Memory (idle)** | ~40-80 MB | ~5-15 MB | Vector |
| **Memory (1K events/s)** | ~120-200 MB | ~20-40 MB | Vector |
| **CPU (1K events/s)** | ~5-10% (1 core) | ~1-3% (1 core) | Vector |
| **Throughput** | ~50-100K events/s | ~500K-1M events/s | Vector |
| **Config format** | Ruby DSL + XML-like | TOML | Subjective (Fluentd is more readable for complex pipelines) |
| **Plugin ecosystem** | ~1,000+ community plugins | ~100+ core + community | Fluentd |
| **Docker log driver** | Native `fluentd` log driver | No native driver (tail file) | Fluentd |
| **ClickHouse sink** | `fluent-plugin-clickhouse` (gem) | `clickhouse` sink (built-in) | Vector (maintained by DataDog) |
| **Forward protocol** | `@type forward` (native) | `vector` source/sink (native) | Tie |
| **Buffer/retry** | Built-in (file/memory) | `buffer` config block | Tie |
| **Multi-line parsing** | `multiline` plugin | `multiline` transform | Fluentd (more mature) |
| **Regex performance** | Onigmo (Ruby) | Rust regex (optimized) | Vector |
| **JSON parsing** | Yajl (C extension) | `serde_json` (Rust) | Tie |
| **Key=value parsing** | `filter_parser` + Kafkaesque kv | `key_value_parser` transform | Tie (both handle it) |
| **Monitoring** | `monitor_agent` HTTP + Prometheus | Built-in Prometheus + internal metrics | Vector |
| **Health check** | `in_monitor` agent | `healthcheck` in config | Tie |
| **Reload config** | SIGHUP (partial) | `vector reload` (full) | Vector |
| **Multi-cluster** | Forward protocol (mature) | `vector` source/sink | Tie |
| **Rate limiting** | `datacounter` plugin | `throttle` transform | Tie |
| **Data masking** | `record_modifier` plugin | `remap` (VRL) | Vector (VRL is more powerful) |
| **Error handling** | `@log_level` + `emit_error_log_interval` | Component-level errors | Vector (more granular) |
| **Community** | Treasure Data, CNCF (incubating) | DataDog (acquired) | Fluentd (broader OSS community) |
| **Maturity** | First release 2011 | First release 2019 | Fluentd (more battle-tested) |
| **Corporate backing** | CNCF (no single vendor) | DataDog | Fluentd (neutral) |

### 6.2 Decision Matrix for Our Use Case

| Requirement | Fluentd | Vector | Notes |
|-------------|---------|--------|-------|
| Parse Go slog key=value | Yes (regexp + key_value) | Yes (regex_parser) | Both need custom regex |
| Write to ClickHouse | Plugin (gem) | Built-in sink | Vector is simpler to configure |
| Multi-cluster forward | Mature `forward` protocol | Native `vector` source/sink | Both work |
| Resource constraint (remote clusters) | Higher memory/Ruby | Lower memory/Rust | Vector wins on sim (40GB disk, 2GB RAM) |
| Docker log driver native | Yes (`fluentd` driver) | No (`docker logs` / file tail) | Fluentd can use native driver |
| Plugin ecosystem | 1000+ plugins | 100+ transforms | Fluentd has more pre-built parsers |
| Configuration complexity | Ruby DSL (steeper learning) | TOML (simpler) | Vector wins for simple pipelines |
| Reliability / buffering | Mature (10+ years) | Proven (5+ years) | Tie |

### 6.3 Per-Cluster Recommendation

| Cluster | Recommended | Rationale |
|---------|-------------|-----------|
| **Mac/Orbstack** (central) | **Vector** (keep current) | Already planned for cc-connect → CK. Lower resource usage. Built-in CK sink. Simpler config for straightforward pipeline. |
| **Aliyun sim** (remote) | **Fluentd** | Need forward protocol to central. Fluentd's forward is more battle-tested. Memory overhead acceptable for a small agent (sim has 2GB RAM, only shipping ~10 containers). |
| **Office nuc8** (remote) | **Fluentd** | Same rationale as Aliyun. Forward protocol over Tailscale is well-documented. nuc8 has enough RAM. |
| **Remote sandbox agents** | **Neither** | Not cost-effective. Sandbox logs are ephemeral. Use `kyb exec` for on-demand log retrieval instead. |

### 6.4 Why Not Consolidate on One

A single log collector is tempting but has tradeoffs:

**All-Vector approach:**
- Pros: Single platform to learn and maintain. Native CK sink. Lower memory on remote hosts.
- Cons: No native `forward` for multi-cluster (requires `vector` source/sink). Less mature multi-cluster story. Fewer pre-built parsers.

**All-Fluentd approach:**
- Pros: Single platform. Battle-tested forward protocol. Richer parser ecosystem.
- Cons: Higher resource usage on resource-constrained hosts. Ruby dependency. CK sink is a community gem, not officially maintained.

**Hybrid (recommended):**
- Central cluster: Vector (direct to CK, lower overhead, simpler config)
- Remote clusters: Fluentd (forward to central, richer parser options for diverse log formats)

The hybrid approach uses each tool's strength: Vector for high-throughput single-pipeline logs, Fluentd for flexible multi-source forwarding.

### 6.5 Migration Path (if abandoning Vector)

If the decision is to go all-Fluentd:

1. **Phase 1**: Deploy Fluentd on remote clusters (Aliyun, Office). Start forwarding logs to central CK.
2. **Phase 2**: Replace Vector on Mac/Orbstack with Fluentd. Test cc-connect parsing side by side.
3. **Phase 3**: Remove Vector. All logs go through Fluentd.
4. **Rollback**: Keep Vector configs in git. Switch back by redeploying old `docker-compose.yml`.

---

## 7. Deployment

### 7.1 Prerequisites

- Docker with `json-file` log driver (current config -- no change needed)
- ClickHouse accessible at `host.orb.internal:8123` (Mac/Orbstack) or via Tailscale IP
- Tailscale mesh for inter-cluster forwarding (already deployed)
- Fluentd image: `fluent/fluentd:v1.18-debian-1`

### 7.2 Deploy on Mac/Orbstack (Central Collector)

```bash
# Create config directory
mkdir -p ~/kyb-infra/fluentd/conf

# Write config (see Section 3)
vim ~/kyb-infra/fluentd/conf/fluentd.conf

# Deploy Fluentd container
docker run -d \
  --name kyb-infra-fluentd \
  --restart unless-stopped \
  -v ~/kyb-infra/fluentd/conf:/fluentd/etc \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v fluentd-pos:/var/log/fluentd \
  -v fluentd-buffer:/fluentd/buffer \
  -e FLUENT_CLUSTER=mac-orbstack \
  -e CLICKHOUSE_HOST=host.orb.internal \
  --network host \
  fluent/fluentd:v1.18-debian-1
```

### 7.3 Deploy on Remote Cluster (Aliyun sim)

```bash
# SSH into sim
ssh dongqs@47.100.71.220

# Create config directory
mkdir -p ~/kyb-infra/fluentd/conf

# Write config with forward sink (see Section 3.6)
vim ~/kyb-infra/fluentd/conf/fluentd.conf

# Deploy Fluentd container
docker run -d \
  --name kyb-infra-fluentd \
  --restart unless-stopped \
  -v ~/kyb-infra/fluentd/conf:/fluentd/etc \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v fluentd-pos:/var/log/fluentd \
  -v fluentd-buffer:/fluentd/buffer \
  -e FLUENT_CLUSTER=aliyun \
  -e CLICKHOUSE_HOST=100.104.244.99 \
  --network host \
  fluent/fluentd:v1.18-debian-1
```

### 7.4 Verify the Deployments

```bash
# Check Fluentd is running
docker ps | grep fluentd

# Check Fluentd logs for startup errors
docker logs kyb-infra-fluentd --tail 50

# Check position file is being written
docker exec kyb-infra-fluentd cat /var/log/fluentd/docker.pos

# Check ClickHouse for incoming data
clickhouse-client --host host.orb.internal \
  --query "SELECT count() FROM cc.message_log WHERE event_time > now() - INTERVAL 5 MINUTE"

# Check buffer usage
docker exec kyb-infra-fluentd ls -la /fluentd/buffer/
```

### 7.5 Grafana Integration

Once Fluentd is writing to `cc.message_log`, the existing Grafana panels (defined in `docs/infra/designs/bridge-ck-ingestion.md`) will automatically show data. No additional Grafana config is needed -- the table and schema are unchanged.

Add a new "Fluentd Health" panel:

```sql
-- Fluentd events per container (last 15 min)
SELECT
    container_name,
    count() AS events
FROM cc.message_log
WHERE event_time > now() - INTERVAL 15 MINUTE
GROUP BY container_name
ORDER BY events DESC
```

---

## 8. Verification

### 8.1 Test the Pipeline End to End

```bash
# Step 1: Generate a test log entry
echo '{"log":"test-fluentd-pipeline-'$(date +%s)'"}' > /tmp/test-fluentd.json

# Step 2: Manually inject into Docker log (simulates a container log line)
# This appends to a container's json.log file
DOCKER_LOG=$(docker inspect kyb-infra-fluentd --format '{{.LogPath}}')
echo "$(cat /tmp/test-fluentd.json)" >> "$DOCKER_LOG"

# Step 3: Wait for Fluentd tail to pick it up (up to pos_file polling interval)
sleep 10

# Step 4: Check ClickHouse for the injected event
clickhouse-client --host host.orb.internal \
  --query "SELECT event_time, container_name FROM cc.message_log ORDER BY event_time DESC LIMIT 5"
```

### 8.2 Test Parser Regex

```bash
# Test Go slog parser
docker exec kyb-infra-fluentd ruby -e '
require "fluent/plugin/parser_regexp"
parser = Fluent::Plugin::RegexpParser.new
parser.configure(
  expression: /^time=(?<time>\S+) level=(?<level>\S+) msg="(?<msg>[^"]*)"(?:\s+(?<kv>.*))?$/
)
text = "time=2026-05-23T16:38:00.604Z level=INFO msg=\"turn complete\" msg_id=om_x123 tools=2"
result = parser.parse(text)
p result
'
```

### 8.3 Test ClickHouse Sink

```bash
# Check ClickHouse connection from Fluentd
docker exec kyb-infra-fluentd ruby -e '
require "fluent/plugin/out_clickhouse"
# Connection test is implicit -- Fluentd will log errors on startup
puts "ClickHouse plugin loaded"
'
```

### 8.4 Monitor Fluentd Health

```bash
# Fluentd exposes a monitoring endpoint (enable with in_monitor)
curl http://localhost:24220/api/plugins.json

# Or check logs for error rate
docker logs kyb-infra-fluentd --tail 100 | grep -c "error"

# Buffer size monitoring
docker exec kyb-infra-fluentd du -sh /fluentd/buffer/
```

### 8.5 Alert Setup

If the pipeline is critical, set up a heartbeat similar to boss heartbeats:

```sql
-- Fluentd health check: events per minute should never drop to 0
-- Expected: >0 events per minute during active Claude sessions
CREATE TABLE infra.fluentd_health (
    hostname String,
    cluster String,
    timestamp DateTime64(3),
    buffer_size_bytes UInt64,
    events_last_minute UInt32,
    errors_last_minute UInt32
) ENGINE = ReplacingMergeTree
ORDER BY (hostname, timestamp);

-- Fluentd can self-report via a healthcheck plugin
-- Or simply monitor cc.message_log: if no new events in 10 min, alert
```

---

## Appendix A: Required Fluentd Plugins

| Plugin | Purpose | Install Command |
|--------|---------|-----------------|
| `fluent-plugin-clickhouse` | ClickHouse sink | `gem install fluent-plugin-clickhouse` |
| `fluent-plugin-grafana-loki` | Loki sink (future) | `gem install fluent-plugin-grafana-loki` |
| `fluent-plugin-prometheus` | Metrics exposition | `gem install fluent-plugin-prometheus` |
| `fluent-plugin-multi-format-parser` | Multi-format parsing | `gem install fluent-plugin-multi-format-parser` |
| `fluent-plugin-record-modifier` | Field manipulation | `gem install fluent-plugin-record-modifier` |

For a custom Docker image:

```dockerfile
FROM fluent/fluentd:v1.18-debian-1
USER root
RUN gem install \
    fluent-plugin-clickhouse \
    fluent-plugin-prometheus \
    fluent-plugin-record-modifier \
    --no-document
USER fluent
```

## Appendix B: Config File Reference

| File | Purpose |
|------|---------|
| `/etc/fluentd/fluentd.conf` | Main config |
| `/etc/fluentd/conf.d/cc-connect.conf` | cc-connect parser + CK sink |
| `/etc/fluentd/conf.d/forward-input.conf` | Receive logs from remote clusters |
| `/etc/fluentd/conf.d/forward-output.conf` | Ship logs to central cluster |
| `/etc/fluentd/plugin/parse_duration.rb` | Go duration parser helper |
| `/var/log/fluentd/docker.pos` | Position file (tailing state) |
| `/fluentd/buffer/*` | Disk buffer files |

---

> **Summary:** Fluentd is a viable log collector for infra containers, particularly strong in multi-cluster forwarding and parser diversity. Recommended as a **hybrid** deployment: keep Vector on the central Mac/Orbstack cluster (simpler CK sink, lower overhead), and deploy Fluentd on remote clusters (Aliyun, Office) where the mature `forward` protocol and richer parser ecosystem add value. The full Fluentd config, parser regex, and ClickHouse sink are documented above for immediate use.

> ／人◕ ‿‿ ◕人＼
