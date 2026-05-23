---
decision: 稍后做
---

# Docker Registry Mirror Latency Monitoring

**Date**: 2026-05-23
**Scope**: Monitor pull speed and availability of Docker registry mirrors -- docker.xuanyuan.me, docker.1ms.run, ACR -- with automatic failover on degradation or failure.

---

## 1. Background

### 1.1 Current Mirror Topology

Three Docker registry mirrors serve the kyb clusters, each with different characteristics:

| Mirror | URL | Used By | Type | Characteristic |
|--------|-----|---------|------|----------------|
| Xuanyuan | `docker.xuanyuan.me` | mac-orbstack, office (nuc8) | Public mirror | General purpose, moderate latency |
| 1ms | `docker.1ms.run` | README recommendation, fallback | Public mirror | High throughput under load, but returns 429 when overloaded |
| ACR | `registry.cn-shanghai.aliyuncs.com/kyb` | Aliyun (sim) | Alibaba Cloud private | Low latency from Aliyun ECS, requires auth |

Additional local cache: `kyb-infra-registry` (pull-through proxy on port 5000) exists on some nodes.

### 1.2 Current Blind Spots

| Gap | Impact |
|-----|--------|
| No ongoing latency tracking | Cannot detect mirror degradation until a `docker pull` times out (~minutes) |
| No historical baseline | "Is this slow or normal?" is answered by gut feel, not data |
| No automatic failover | When mirror returns 429 or hangs, builds fail. User must manually edit `daemon.json` or `config.yml` |
| No cross-mirror comparison | Don't know which mirror is fastest right now for this node |
| No ACR auth health check | ACR token expiry causes silent pull failures with opaque "unauthorized" errors |

### 1.3 Mirror Failure Modes

| Failure | Symptom | Recovery |
|---------|---------|----------|
| DNS failure | `dial tcp: lookup docker.xuanyuan.me: no such host` | Switch to alternative mirror |
| HTTP 429 (rate limit) | `toomanyrequests: rate limit exceeded` | 1ms mirror returns this under load; retry after backoff |
| HTTP 5xx | `Service Unavailable` or `Internal Server Error` | Mirror upstream is degraded; switch immediately |
| Slow but alive | Pull completes but takes >30s for a small layer | Degradation alert; consider switching if sustained |
| ACR token expired | `unauthorized: authentication required` | Refresh token or fall back to public mirror |
| TLS cert expired | `x509: certificate has expired` | Emergency switch; mirror operator must fix |

---

## 2. Design Goals

1. **Probe every mirror every 60s** from each cluster boss -- measure HTTP response time for manifest list HEAD request
2. **Track in ClickHouse** -- per-probe latency, HTTP status, error type, mirror identity
3. **Grafana dashboard** -- real-time latency per mirror, historical trends, availability heatmap
4. **Auto-failover** -- when primary mirror exceeds threshold, swap to best alternative in `daemon.json` or `config.yml`
5. **Alert on degradation** -- latency >5s sustained, >50% failure rate over 5min window

### Non-Goals

- Inter-node coordination for failover (each node decides independently)
- Mirror-to-mirror content sync verification (assume standard Docker Hub content)
- Write-back or push-through cache warming

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Each cluster boss (mac-orbstack / aliyun / office)              │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  kyb-infra-boss container                                   │  │
│  │  ┌────────────────────────────────────┐                     │  │
│  │  │  registry-probe (bash+curl)       │                     │  │
│  │  │  ┌──────────┐  ┌──────────┐  ┌────┴─────┐              │  │
│  │  │  │ Xuanyuan │  │ 1ms      │  │ ACR      │              │  │
│  │  │  │ probe    │  │ probe    │  │ probe    │              │  │
│  │  │  └────┬─────┘  └────┬─────┘  └────┬─────┘              │  │
│  │  │       └─────────────┼──────────────┘                    │  │
│  │  │                     ▼                                   │  │
│  │  │             Write result to file                        │  │
│  │  └─────────────────────────────────────────────────────────┘  │
│  │                           │                                    │
│  │  ┌─────────────────────────────────────────────────────────┐  │
│  │  │  Vector / tail+curl pipeline                            │  │
│  │  │  Reads probe results → writes to CK                     │  │
│  │  └─────────────────────────────────────────────────────────┘  │
│  └────────────────────────────────────────────────────────────────┘
│                    │
│                    ▼
│  ┌─────────────────────────────────────┐
│  │  /etc/docker/daemon.json            │
│  │  registry-mirrors list (ordered)    │
│  │  → auto-failover rewrites this      │
│  └─────────────────────────────────────┘
└──────────────────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
  ┌──────────────────┐             ┌──────────────────┐
  │  ClickHouse      │             │  Grafana         │
  │  infra.mirror_   │             │  CK datasource   │
  │  probe_history   │             │  + alert rules   │
  └──────────────────┘             └──────────────────┘
```

### 2.1 Components

| Component | Role | Deployment |
|-----------|------|------------|
| **registry-probe** | Probes each mirror every 60s, measures latency | Bash script on each infra-boss, runs as cron or systemd timer |
| **Vector** | Reads probe output files, ships to CK | Existing Vector deployment (or add to existing pipeline) |
| **ClickHouse** | `infra.mirror_probe_history` + `infra.mirror_status_latest` | Existing `host.orb.internal:9000` |
| **Grafana** | Dashboards + alert rules | Existing infra Grafana |
| **failoverd** | Rewrites daemon.json on degradation | Shell script triggered by probe when threshold breached |

---

## 4. Probe Design

### 4.1 Probe Method

The probe issues a lightweight HTTP HEAD request to each mirror's `v2/` endpoint (Docker Registry API root). This retrieves the API version response without pulling any blobs or manifests -- minimal bandwidth, fast.

```
HEAD https://docker.xuanyuan.me/v2/
HEAD https://docker.1ms.run/v2/
HEAD https://registry.cn-shanghai.aliyuncs.com/v2/kyb/
```

**Why HEAD `/v2/`:**
- Docker Hub compatible API -- all three mirrors support it
- Response is small (headers only, ~200 bytes)
- No auth required for public mirrors; ACR returns `401 Unauthorized` + `Www-Authenticate` which is expected and tells us the endpoint is alive
- Does NOT consume rate limit quota (HEAD requests are typically not counted)

**Metrics per probe:**

| Field | Source | Example |
|-------|--------|---------|
| mirror_name | Config | `docker.xuanyuan.me` |
| target_url | Probe URL | `https://docker.xuanyuan.me/v2/` |
| http_status | curl `-w %{http_code}` | `200`, `401`, `429`, `503` |
| latency_ms | curl `-w %{time_total}` | `1234` (ms) |
| error_type | Parsed from response/error | `ok`, `rate_limited`, `timeout`, `dns_failure`, `tls_error`, `auth_required` |
| dns_lookup_ms | curl `-w %{time_namelookup}` | `45` |
| connect_ms | curl `-w %{time_connect}` | `120` |
| tls_ms | curl `-w %{time_appconnect}` | `250` |
| probe_source | Hostname | `mac-orbstack` / `aliyun-sim` / `office-nuc8` |
| probe_timestamp | ISO 8601 | `2026-05-23T10:00:00Z` |

### 4.2 Probe Script

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/registry-probe
# Probe all configured Docker registry mirrors and write results to stdout (JSON Lines).
# One line per mirror per probe cycle.
#
# Usage: registry-probe
# Output: NDJSON to stdout, one object per mirror

set -euo pipefail

# Config: mirrors to probe
MIRRORS=(
  "https://docker.xuanyuan.me/v2/"
  "https://docker.1ms.run/v2/"
  "https://registry.cn-shanghai.aliyuncs.com/v2/kyb/"
)

PROBE_SOURCE="$(hostname -s 2>/dev/null || echo 'unknown')"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

for mirror_url in "${MIRRORS[@]}"; do
  mirror_name="$(echo "$mirror_url" | sed -E 's|https?://([^/]+)/.*|\1|')"

  # curl with detailed timing
  output=$(curl -sS -o /dev/null \
    -w "%{http_code}\t%{time_total}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}" \
    --max-time 15 \
    --connect-timeout 10 \
    -X HEAD \
    "$mirror_url" 2>&1) || true

  # Parse curl output
  http_code="$(echo "$output" | cut -f1)"
  latency_s="$(echo "$output" | cut -f2)"
  dns_s="$(echo "$output" | cut -f3)"
  connect_s="$(echo "$output" | cut -f4)"
  tls_s="$(echo "$output" | cut -f5)"
  start_s="$(echo "$output" | cut -f6)"

  # Compute ms values
  latency_ms=$(awk "BEGIN {printf \"%.0f\", $latency_s * 1000}" 2>/dev/null || echo "null")
  dns_ms=$(awk "BEGIN {printf \"%.0f\", $dns_s * 1000}" 2>/dev/null || echo "null")
  connect_ms=$(awk "BEGIN {printf \"%.0f\", $connect_s * 1000}" 2>/dev/null || echo "null")
  tls_ms=$(awk "BEGIN {printf \"%.0f\", $tls_s * 1000}" 2>/dev/null || echo "null")

  # Determine error type
  if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
    # curl failed -- classify by error message
    if echo "$output" | grep -qi "timeout\|timed out"; then
      error_type="timeout"
    elif echo "$output" | grep -qi "could not resolve\|name or service not known"; then
      error_type="dns_failure"
    elif echo "$output" | grep -qi "certificate\|ssl\|tls"; then
      error_type="tls_error"
    elif echo "$output" | grep -qi "connection refused"; then
      error_type="connection_refused"
    else
      error_type="unknown_error"
    fi
    http_code=0
    latency_ms="null"
  elif [ "$http_code" = "429" ]; then
    error_type="rate_limited"
  elif [ "$http_code" = "401" ]; then
    error_type="auth_required"
  elif [ "$http_code" -ge 500 ]; then
    error_type="server_error"
  else
    error_type="ok"
  fi

  # Output NDJSON
  cat <<ENDJSON
{"timestamp":"${TIMESTAMP}","mirror":"${mirror_name}","probe_source":"${PROBE_SOURCE}","http_status":${http_code},"latency_ms":${latency_ms},"dns_ms":${dns_ms},"connect_ms":${connect_ms},"tls_ms":${tls_ms},"error_type":"${error_type}"}
ENDJSON
done
```

**Output example (NDJSON, one object per mirror per run):**

```json
{"timestamp":"2026-05-23T10:00:00Z","mirror":"docker.xuanyuan.me","probe_source":"mac-orbstack","http_status":200,"latency_ms":1234,"dns_ms":45,"connect_ms":120,"tls_ms":250,"error_type":"ok"}
{"timestamp":"2026-05-23T10:00:01Z","mirror":"docker.1ms.run","probe_source":"mac-orbstack","http_status":429,"latency_ms":null,"dns_ms":30,"connect_ms":80,"tls_ms":200,"error_type":"rate_limited"}
{"timestamp":"2026-05-23T10:00:02Z","mirror":"registry.cn-shanghai.aliyuncs.com","probe_source":"mac-orbstack","http_status":401,"latency_ms":350,"dns_ms":10,"connect_ms":20,"tls_ms":50,"error_type":"auth_required"}
```

### 4.3 Probe Scheduling

Run every 60 seconds on each infra-boss container:

```bash
# Via systemd timer (preferred -- survives container restart)
# /etc/systemd/system/registry-probe.timer
[Unit]
Description=Registry mirror probe timer

[Timer]
OnCalendar=minutely
Persistent=true

[Install]
WantedBy=timers.target

# /etc/systemd/system/registry-probe.service
[Unit]
Description=Probe Docker registry mirrors

[Service]
Type=oneshot
ExecStart=/home/dev/.kyb/bin/registry-probe >> /var/log/registry-probe.ndjson
```

**Alternative (cron, for environments without systemd):**

```bash
* * * * * /home/dev/.kyb/bin/registry-probe >> /var/log/registry-probe.ndjson 2>&1
```

---

## 5. ClickHouse Schema

### 5.1 `infra.mirror_probe_history` -- raw probe records

```sql
CREATE TABLE infra.mirror_probe_history (
    event_time      DateTime64(3)        COMMENT 'Probe timestamp (from probe script)',
    probe_source    LowCardinality(String) COMMENT 'Hostname of probing node (mac-orbstack, aliyun-sim, office-nuc8)',
    mirror          LowCardinality(String) COMMENT 'Mirror hostname (docker.xuanyuan.me, docker.1ms.run, registry.cn-shanghai.aliyuncs.com)',
    http_status     UInt16               COMMENT 'HTTP response status code (0 = probe failed before HTTP)',
    latency_ms      Nullable(UInt32)     COMMENT 'Total request latency in ms (null if probe failed)',
    dns_ms          Nullable(UInt16)     COMMENT 'DNS lookup time in ms',
    connect_ms      Nullable(UInt16)     COMMENT 'TCP connect time in ms',
    tls_ms          Nullable(UInt16)     COMMENT 'TLS handshake time in ms',
    error_type      LowCardinality(String) COMMENT 'Classified error: ok, rate_limited, timeout, dns_failure, tls_error, server_error, auth_required, connection_refused, unknown_error',

    -- Derived at query time if needed:
    -- is_degraded: latency_ms > 5000 OR http_status >= 429
    -- is_down:    error_type != 'ok' AND error_type != 'auth_required'
) ENGINE = MergeTree
ORDER BY (event_time, mirror, probe_source)
TTL event_time + INTERVAL 90 DAY
```

**Design notes:**
- 90-day retention -- long enough for trend analysis (ISP routing changes, seasonal latency variation)
- `LowCardinality` on `mirror`, `probe_source`, `error_type` -- these repeat every run, compression is excellent
- Separate timing fields (`dns_ms`, `connect_ms`, `tls_ms`) enable drill-down into *where* latency is spent
- `http_status = 0` means the probe never got an HTTP response (DNS/TCP/TLS failure)
- `error_type` is classification, not raw error string -- keeps cardinality low

### 5.2 `infra.mirror_status_latest` -- materialized current health per mirror

```sql
CREATE MATERIALIZED VIEW infra.mirror_status_latest
ENGINE = ReplacingMergeTree(event_time)
ORDER BY (mirror, probe_source)
POPULATE AS
SELECT
    mirror,
    probe_source,
    argMax(event_time, event_time)          AS last_probe_time,
    argMax(http_status, event_time)         AS last_http_status,
    argMax(latency_ms, event_time)          AS last_latency_ms,
    argMax(error_type, event_time)          AS last_error_type,
    count(*)                                 AS probe_count_24h,
    countIf(error_type = 'ok')              AS ok_count_24h,
    countIf(error_type != 'ok')             AS fail_count_24h,
    max(latency_ms)                          AS max_latency_24h,
    avg(latency_ms)                          AS avg_latency_24h
FROM infra.mirror_probe_history
WHERE event_time > now() - INTERVAL 24 HOUR
GROUP BY mirror, probe_source
```

This view always reflects the latest known status per mirror-per-node, plus 24h statistics.

### 5.3 `infra.mirror_failover_events` -- failover audit log

```sql
CREATE TABLE infra.mirror_failover_events (
    event_time      DateTime64(3)        COMMENT 'Failover trigger time',
    probe_source    LowCardinality(String) COMMENT 'Node that performed failover',
    old_mirror      LowCardinality(String) COMMENT 'Previously active mirror',
    new_mirror      LowCardinality(String) COMMENT 'Mirror switched to',
    reason          String               COMMENT 'Trigger condition (e.g., "5xx rate >50% in 5min", "latency >10s")',
    daemon_json     String               COMMENT 'New daemon.json content (redacted)'
) ENGINE = MergeTree
ORDER BY (event_time, probe_source)
TTL event_time + INTERVAL 365 DAY
```

**Design notes:**
- 365-day retention -- failover events are rare (hopefully) and valuable for post-mortem
- `daemon_json` captures the full `registry-mirrors` list after the switch for forensic analysis

---

## 6. Collection Pipeline

### 6.1 Vector Configuration (on each infra-boss)

Read the NDJSON probe output file and ship to ClickHouse:

```toml
# /etc/vector/vector.toml (or add to existing config)
[sources.registry_probes]
type = "file"
include = ["/var/log/registry-probe.ndjson"]
fingerprint.strategy = "device_and_inode"

[transforms.parse_probes]
type = "remap"
inputs = ["registry_probes"]
source = '''
  # Parse NDJSON
  . = parse_json!(.message)

  # Rename fields to CK column names
  .event_time = parse_timestamp!(.timestamp, format: "%+")
  .probe_source = .probe_source
  .mirror = .mirror
  .http_status = to_int!(.http_status)
  .latency_ms = to_int!(.latency_ms) ?? null
  .dns_ms = to_int!(.dns_ms) ?? null
  .connect_ms = to_int!(.connect_ms) ?? null
  .tls_ms = to_int!(.tls_ms) ?? null
  .error_type = .error_type

  # Remove raw JSON fields that don't map to CK columns
  del(.timestamp)
'''

[sinks.mirror_probes]
type = "clickhouse"
inputs = ["parse_probes"]
endpoint = "http://host.orb.internal:8123"
database = "infra"
table = "mirror_probe_history"
compression = "lz4"

[ sinks.mirror_probes.batch ]
max_events = 50
timeout_secs = 5
```

---

## 7. Auto-Failover Mechanism

### 7.1 Decision Logic

The failover script `~/.kyb/bin/registry-failoverd` runs every 5 minutes and evaluates the last 5 minutes of probe history:

```
Rule 1: IF any mirror has >50% error rate in last 5 min
        AND current active mirror is the failing one
        THEN switch to the best-performing alternative

Rule 2: IF current mirror's avg latency > 5s in last 5 min
        AND an alternative has avg latency < 2s
        THEN switch to the faster alternative

Rule 3: IF current mirror restored to < 1s latency for 2 consecutive checks
        AND an alternative is not significantly slower
        THEN stay (no unnecessary flip-flop)

Rule 4: IF all mirrors are degraded (rare -- likely network issue)
        THEN keep current mirror, alert but do NOT switch
```

### 7.2 Failover Script

```bash
#!/usr/bin/env bash
# ~/.kyb/bin/registry-failoverd
# Evaluate mirror health and auto-switch daemon.json if needed.
#
# Usage: registry-failoverd [--dry-run]
#   --dry-run: print what would change without modifying anything

set -euo pipefail

DRY_RUN="${1:-}"
DAEMON_JSON="/etc/docker/daemon.json"
PROBE_LOG="/var/log/registry-probe.ndjson"
PROBE_SOURCE="$(hostname -s)"

# Mirror priority order (tiebreaker)
MIRROR_PRIORITY=("docker.xuanyuan.me" "docker.1ms.run" "registry.cn-shanghai.aliyuncs.com")

# Thresholds
ERROR_THRESHOLD=0.5        # 50% error rate triggers failover
LATENCY_BAD_THRESHOLD=5000 # 5s average latency triggers failover (ms)
LATENCY_GOOD_THRESHOLD=1000 # 1s = mirror is healthy (ms)
WINDOW_MINUTES=5           # evaluation window

analyze_mirror() {
  local mirror="$1"
  local window_sec=$((WINDOW_MINUTES * 60))

  # Read last N minutes from probe log (filtered for this mirror + host)
  local probes
  probes=$(grep "\"mirror\":\"${mirror}\"" "$PROBE_LOG" 2>/dev/null | \
           grep "\"probe_source\":\"${PROBE_SOURCE}\"" | \
           tail -n 20)

  [ -z "$probes" ] && echo "no_data 0 0 null" && return

  local total=0 fails=0 latencies=()
  while IFS= read -r line; do
    total=$((total + 1))
    error_type=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['error_type'])" 2>/dev/null)
    latency=$(echo "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('latency_ms','null') or 'null')" 2>/dev/null)

    if [ "$error_type" != "ok" ]; then
      fails=$((fails + 1))
    fi
    if [ "$latency" != "null" ]; then
      latencies+=("$latency")
    fi
  done <<< "$probes"

  local error_rate
  error_rate=$(awk "BEGIN {printf \"%.3f\", $fails / $total}")

  # Compute avg latency
  local avg_latency="null"
  if [ ${#latencies[@]} -gt 0 ]; then
    local sum=0
    for l in "${latencies[@]}"; do sum=$((sum + l)); done
    avg_latency=$((sum / ${#latencies[@]}))
  fi

  echo "${error_rate} ${total} ${avg_latency}"
}

get_active_mirror() {
  # Read current registry-mirrors from daemon.json (first entry)
  python3 -c "
import json
with open('$DAEMON_JSON') as f:
    cfg = json.load(f)
mirrors = cfg.get('registry-mirrors', [])
print(mirrors[0] if mirrors else 'none')
" 2>/dev/null || echo "unknown"
}

select_best_mirror() {
  # Evaluate each mirror and return the best one
  local best=""
  local best_score=999999

  for mirror in "${MIRROR_PRIORITY[@]}"; do
    read -r err_rate count avg_lat <<< "$(analyze_mirror "$mirror")"

    # Skip mirrors with no data
    [ "$count" = "0" ] && continue
    [ "$avg_lat" = "null" ] && avg_lat=99999

    # Compute score: lower is better
    # Error rate penalty: multiply latency by (1 + 10 * error_rate)
    local score
    score=$(awk "BEGIN {printf \"%.0f\", $avg_lat * (1 + 10 * $err_rate)}")


    if [ "$score" -lt "$best_score" ]; then
      best_score=$score
      best=$mirror
    fi
  done

  echo "$best"
}

# ── Main ──

active=$(get_active_mirror)
echo "[$(date -u +%H:%M:%S)] Current active mirror: $active"

best=$(select_best_mirror)
echo "[$(date -u +%H:%M:%S)] Best mirror: $best"

if [ -z "$best" ] || [ "$best" = "$active" ]; then
  echo "[$(date -u +%H:%M:%S)] No switch needed (current is best or no alternatives)"
  exit 0
fi

# Check if active mirror is actually degraded
read -r active_err active_count active_lat <<< "$(analyze_mirror "$active")"
if [ "$active_count" = "0" ]; then
  # No data for active mirror -- do nothing (avoid blank-slate flip)
  echo "[$(date -u +%H:%M:%S)] No data for active mirror, skipping failover"
  exit 0
fi

should_switch=false
reason=""

# Rule 1: Error rate too high
if awk "BEGIN {exit ($active_err < $ERROR_THRESHOLD)}"; then
  should_switch=true
  reason="error_rate=${active_err} > threshold=${ERROR_THRESHOLD}"
fi

# Rule 2: Latency too high
if [ "$active_lat" != "null" ] && awk "BEGIN {exit ($active_lat < $LATENCY_BAD_THRESHOLD)}"; then
  should_switch=true
  reason="${reason} latency=${active_lat}ms > ${LATENCY_BAD_THRESHOLD}ms"
fi

if [ "$should_switch" = true ]; then
  echo "[$(date -u +%H:%M:%S)] FAILOVER: $active -> $best (reason: $reason)"

  if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "[DRY-RUN] Would rewrite $DAEMON_JSON with mirror = $best"
    echo "[DRY-RUN] Would restart Docker daemon"
    exit 0
  fi

  # Bail if we're in a container (don't kill the host's Docker)
  if [ -f /.dockerenv ]; then
    echo "[WARN] Running inside container -- cannot restart Docker daemon"
    echo "[WARN] Writing recommendation to /tmp/recommended-mirror instead"
    echo "$best" > /tmp/recommended-mirror
    exit 0
  fi

  # Rewrite daemon.json
  python3 -c "
import json
with open('$DAEMON_JSON') as f:
    cfg = json.load(f)
cfg['registry-mirrors'] = ['https://$best']
with open('$DAEMON_JSON', 'w') as f:
    json.dump(cfg, f, indent=2)
"

  # Reload Docker daemon (SIGHUP, no restart needed)
  kill -HUP $(pidof dockerd) 2>/dev/null || true

  echo "[$(date -u +%H:%M:%S)] Switched to $best, Docker reloaded"

  # Log to CK via Vector
  failover_ndjson="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"probe_source\":\"$PROBE_SOURCE\",\"old_mirror\":\"$active\",\"new_mirror\":\"$best\",\"reason\":\"$reason\"}"
  echo "$failover_ndjson" >> /var/log/registry-failover.ndjson
else
  echo "[$(date -u +%H:%M:%S)] Active mirror is healthy, no switch needed"
fi
```

### 7.3 Integration with kyb config

When running inside a kyb container (not modifying host Docker), the failover writes to `/tmp/recommended-mirror`. The `kyb build` command reads this file to select the best mirror for `--build-arg BUILD_ALL_PROXY` and Docker pull operations.

The `~/.config/kyb/config.yml` supports a `registry_mirror` key per project. The failover daemon can also update this:

```bash
# Update config.yml registry_mirror
python3 -c "
import yaml
cfg = yaml.safe_load(open('/home/dev/.config/kyb/config.yml'))
cfg['base']['registry_mirror'] = '$new_mirror'
with open('/home/dev/.config/kyb/config.yml', 'w') as f:
    yaml.dump(cfg, f)
"
```

### 7.4 Anti-Flap Protection

To prevent rapid oscillation between mirrors:

| Mechanism | Details |
|-----------|---------|
| Cooldown period | After a failover, no further automatic switches for 15 minutes |
| Staggered thresholds | Switch-away threshold (5s) is much higher than switch-back threshold (1.5s to consider returning) |
| Minimum evaluation window | 5 minutes of data required; never switch on a single probe |
| N-minute hold | After switching, the old mirror is excluded from the best-mirror evaluation for 30 minutes |
| Rate-limited handling | 429 errors get exponential backoff before re-probing (15s, 30s, 60s) |

---

## 8. Grafana Dashboards

### 8.1 Mirror Latency Overview

| Panel | Query | Description |
|-------|-------|-------------|
| Current Latency per Mirror | `SELECT mirror, avgState(avg_latency_24h) FROM infra.mirror_status_latest GROUP BY mirror` | Stat panel showing current average latency |
| Active Mirror per Node | `SELECT probe_source, mirror, last_latency_ms FROM infra.mirror_status_latest` | Table: which mirror each node is using |
| Availability Heatmap | `SELECT toStartOfHour(event_time) AS h, mirror, countIf(error_type='ok')/count()*100 AS avail_pct FROM infra.mirror_probe_history WHERE event_time > now() - 7d GROUP BY h, mirror` | Heatmap: green=100%, red=0% per hour per mirror |
| Latency Time Series | `SELECT event_time, mirror, avg(latency_ms) AS lat FROM infra.mirror_probe_history WHERE event_time > now() - 1h GROUP BY event_time, mirror` | Multi-line chart, one line per mirror, last hour |

### 8.2 Failure Analysis

| Panel | Query | Description |
|-------|-------|-------------|
| Error Rate | `SELECT event_time, mirror, countIf(error_type!='ok')/count()*100 AS err_rate FROM infra.mirror_probe_history WHERE event_time > now() - 1h GROUP BY event_time, mirror` | Percentage of failed probes over time |
| Error Breakdown | `SELECT mirror, error_type, count() AS cnt FROM infra.mirror_probe_history WHERE event_time > now() - 24h GROUP BY mirror, error_type` | Stacked bar of error types per mirror |
| Failover Events | `SELECT event_time, probe_source, old_mirror, new_mirror, reason FROM infra.mirror_failover_events ORDER BY event_time DESC LIMIT 20` | Event log table |

### 8.3 Drill-Down: Detailed Timing

| Panel | Query | Description |
|-------|-------|-------------|
| DNS vs Connect vs TLS | `SELECT event_time, mirror, avg(dns_ms), avg(connect_ms), avg(tls_ms) FROM infra.mirror_probe_history WHERE event_time > now() - 1h AND mirror='docker.xuanyuan.me' GROUP BY event_time, mirror` | Stacked area: where does the time go? |
| Latency Distribution | `SELECT mirror, latency_ms FROM infra.mirror_probe_history WHERE event_time > now() - 1h AND error_type='ok'` | Histogram (Grafana heatmap) |

### 8.4 Alert Rules (Grafana)

| Rule | Condition | Severity | Action |
|------|-----------|----------|--------|
| **MirrorDown** | All probes to a mirror fail for >2 consecutive checks (2 min) | P1 | Feishu notification + tag on-call |
| **MirrorDegraded** | >30% error rate on any mirror over 5 min | P2 | Feishu notification |
| **LatencySpike** | Avg latency >5s for 5 min on active mirror | P2 | Feishu notification |
| **FailoverEvent** | Any row in `mirror_failover_events` | P2 | Feishu notification with switch details |
| **AllMirrorsDown** | All mirrors have >90% error rate over 5 min | P1 | Urgent -- likely DNS or proxy issue, not mirrors |
| **NoProbeData** | No probe data for any mirror in 10 min | P3 | Probe script or Vector may be down |
| **ACRAuthFail** | ACR returns 401 consistently (token expired) | P3 | Need to refresh ACR credentials |

---

## 9. Implementation Checklist

### Phase 1: Probe + Data Pipeline (< 1 day)
- [ ] Write `~/.kyb/bin/registry-probe` probe script
- [ ] Create `/var/log/registry-probe.ndjson` with proper permissions
- [ ] Deploy cron or systemd timer for 60s interval on each infra-boss
- [ ] Create `infra.mirror_probe_history` table in ClickHouse
- [ ] Configure Vector to read probe output file and write to CK
- [ ] Verify data flows: `SELECT count() FROM infra.mirror_probe_history`
- [ ] Create `infra.mirror_status_latest` materialized view
- [ ] Deploy on all three cluster bosses (mac-orbstack, aliyun-sim, office-nuc8)

### Phase 2: Grafana Dashboards (< 2h)
- [ ] Build "Mirror Latency Overview" dashboard (4-6 panels)
- [ ] Build "Mirror Failure Analysis" dashboard (3 panels)
- [ ] Build "Mirror Timing Drill-Down" dashboard (2 panels)
- [ ] Create `infra.mirror_failover_events` table
- [ ] Configure alert rules (start with MirrorDown and FailoverEvent, add others after baseline)

### Phase 3: Auto-Failover (< 1 day)
- [ ] Write `~/.kyb/bin/registry-failoverd` script
- [ ] Test in --dry-run mode on each node
- [ ] Verify daemon.json rewriting and Docker reload on orbstack
- [ ] Deploy on aliyun-sim (most impacted by mirror failures -- limited bandwidth)
- [ ] Deploy on office-nuc8
- [ ] Consider if mac-orbstack needs auto-failover (local OrbStack pulls are fast; failover less urgent)
- [ ] Wire /tmp/recommended-mirror into `kyb build` for containerized usage

### Phase 4: Post-Deployment Tuning (after 1 week baseline)
- [ ] Evaluate and tune thresholds (error_rate, latency_bad) based on real data
- [ ] Tweak anti-flap parameters if oscillation observed
- [ ] Add probe_source dimension filtering to all dashboards
- [ ] Review alert noise and tune as needed

---

## 10. Integration Points

### 10.1 `kyb preflight`

Add registry mirror health check to the existing `kyb preflight` flow. After checking proxy and endpoints, run a quick probe against all mirrors and report status:

```
[  OK] docker.xuanyuan.me  — 234ms
[  OK] docker.1ms.run      — 567ms
[ WARN] ACR                — 401 (auth required)
```

This uses the same probe logic but runs once synchronously (no daemon needed).

### 10.2 `kyb build`

During `kyb build`, if `/tmp/recommended-mirror` exists, use it for `--build-arg` and Docker pull operations:

```ruby
# lib/kyb/build.rb (proposed)
def self.recommended_mirror
  path = '/tmp/recommended-mirror'
  File.exist?(path) ? File.read(path).strip : nil
end
```

### 10.3 Patrol Integration

Add to the 5-minute patrol prompt:
- Query `infra.mirror_status_latest` for any mirror with `last_error_type != 'ok'`
- Report degraded mirrors in the patrol summary
- If a failover occurred since last patrol, mention it explicitly

### 10.4 Feishu Notifications

Use `kyb notify` to alert on failover events:

```bash
kyb notify urgent "Mirror failover: docker.xuanyuan.me -> docker.1ms.run on mac-orbstack (error_rate=0.6)"
```

---

## 11. Resource Estimation

| Table | Rows/day (est) | Row size | Daily volume | Retention | Total storage |
|-------|-----------------|----------|--------------|-----------|---------------|
| `infra.mirror_probe_history` | ~4,320 (60s x 3 mirrors x 1 node) | ~120 B | ~0.5 MB | 90 days | ~45 MB |
| `infra.mirror_probe_history` (3 nodes) | ~12,960 | ~120 B | ~1.5 MB | 90 days | ~135 MB |
| `infra.mirror_failover_events` | ~5 (rare) | ~300 B | ~1.5 KB | 365 days | ~0.5 MB |
| **Total** | | | **~1.5 MB** | | **~135 MB** |

Compression (CK columnar + LowCardinality + LZ4) reduces actual disk usage by 5-8x -> **~17-27 MB total**. Negligible impact.

---

## 12. Future Considerations

- **Per-layer download speed**: Instead of just HEAD `/v2/`, probe actual blob download speed by pulling a small known blob (e.g., `busybox:latest` manifest). Gives real throughput data but costs bandwidth.
- **Geo-distributed probes**: If kyb expands to more regions (HK, Singapore, US-West), add probe sources for geographic latency comparison. Can then recommend the fastest mirror per region.
- **Mirror-to-mirror sync**: For private ACR, sync frequently-used images from public mirrors to ACR during off-peak hours. Reduces cold-cache penalty on first pull.
- **Prometheus exporter mode**: Instead of cur pipeline, run a Prometheus exporter that exposes per-mirror latency metrics. Would integrate with existing Prometheus infra if one exists.
- **GitLab registry**: If CI runners use the same mirrors, extend probes to cover the GitLab registry endpoint. Different latency profile (GitLab vs Docker Hub mirrors).
- **Mirror ranking API**: A lightweight HTTP endpoint on the infra-boss that answers "which mirror should I use?" so any container can query it during startup.

---

## 13. References

- [Registry Cache Deploy](../handbook/registry-cache-deploy.md) -- existing local registry cache setup
- [Multi-Cluster Boss Architecture](../multi-cluster-boss-architecture.md) -- `registry_mirror` per-cluster config
- [Observability Design](../observability-design.md) -- observability patterns used in this project
- [Pre-flight Check Source](../../lib/kyb/check.rb) -- existing endpoint check logic (reference for probe timing)
- [Docker Registry V2 API](https://docs.docker.com/registry/spec/api/) -- API used for probes
- [Docker Registry Mirror Config](https://docs.docker.com/registry/recipes/mirror/) -- daemon.json mirror syntax
- [Sing-Box Metrics Design](sing-box-metrics.md) -- prior art for curl-based probe + CK pipeline
