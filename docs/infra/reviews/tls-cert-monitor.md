---
decision: 稍后做
---

# TLS Certificate Expiry Monitoring

> **Status:** Design Document  
> **Date:** 2026-05-23  
> **Context:** Monitor all infrastructure TLS certificates for expiry, alert at 30/14/7 days before expiration, integrate with existing ClickHouse + Grafana observability.

---

## Table of Contents

1. [Current Certificate Inventory](#1-current-certificate-inventory)
2. [Architecture](#2-architecture)
3. [Check Script](#3-check-script)
4. [Alert Thresholds & Escalation](#4-alert-thresholds--escalation)
5. [ClickHouse Schema](#5-clickhouse-schema)
6. [Grafana Dashboard](#6-grafana-dashboard)
7. [Deployment](#7-deployment)
8. [Renewal Procedures](#8-renewal-procedures)
9. [Future: ACME Auto-Renewal](#9-future-acme-auto-renewal)

---

## 1. Current Certificate Inventory

### 1.1 Self-Managed Certificates (Our Responsibility)

| Domain / Service | Issuer | Issued | Expires | Days Remaining (May 23) | Renewal Method |
|---|---|---|---|---|---|
| `docker.xuanyuan.me:443` | Google Trust Services (WE1) / Let's Encrypt | 2026-05-07 | 2026-08-05 | ~74 | Manual, LE certbot |
| `git.leyantech.com:443` | DigiCert / RapidSSL | 2026-02-24 | 2026-09-10 | ~110 | Managed by GitLab IT (track only) |
| `registry.cn-shanghai.aliyuncs.com:443` | GlobalSign GCC R3 OV TLS CA 2024 | 2025-12-23 | 2027-01-24 | ~246 | Managed by Alibaba Cloud (track only) |
| `github.com:443` | Sectigo DV CA | 2026-05-05 | 2026-08-02 | ~71 | Managed by GitHub (track only) |

### 1.2 Self-Managed Services (To Be Monitored)

These are the services we operate that have or should have TLS:

| Service | Host | Current TLS | Action Required |
|---|---|---|---|
| **docker.xuanyuan.me** | Docker registry | LE/WE1, 90-day | Auto-renew, monitor expiry |
| **Grafana** (port 3000) | Mac/Orbstack | No TLS | Track-only for now (internal-only) |
| **ClickHouse** (port 8123) | Mac/Orbstack | No TLS | Track-only (internal, no secrets in transit) |
| **Registry cache** (port 5000) | Mac/Orbstack | No TLS | Track-only (internal HTTP, insecure-registries) |
| **PostgreSQL** (5432-5437) | Mac/Orbstack | No TLS | Track-only (internal, trust auth) |
| **Redis** (6379) | Mac/Orbstack | No TLS | Track-only (internal) |
| **Kafka** (9092) | Mac/Orbstack | No TLS | Track-only (internal) |
| **sing-box** (2080) | Mac/Orbstack | No TLS | SOCKS5 proxy, no TLS needed |
| **cc-connect** (9111/9810/9820) | Mac/Orbstack | No TLS | Track-only (internal) |

### 1.3 Third-Party Managed (Track Only)

| Domain | Managed By | Expiry | Risk |
|---|---|---|---|
| `git.leyantech.com` | GitLab IT / DigiCert | 2026-09-10 | Low (IT auto-renews) |
| `registry.cn-shanghai.aliyuncs.com` | Alibaba Cloud | 2027-01-24 | Low (cloud-managed) |
| `github.com` | GitHub / Sectigo | 2026-08-02 | Very low (GitHub manages) |

> **Principle:** Monitor all TLS endpoints but only alert on self-managed ones. Third-party
> endpoints are tracked for awareness; their expiry is not actionable by us.

### 1.4 Verification Commands (Reference)

```bash
# Check any TLS endpoint's expiration
check_cert() {
  local host=$1 port=${2:-443}
  openssl s_client -connect "${host}:${port}" -servername "${host}" \
    </dev/null 2>/dev/null \
    | openssl x509 -noout -dates -subject -issuer 2>/dev/null
}

# Usage
check_cert docker.xuanyuan.me
check_cert git.leyantech.com
check_cert registry.cn-shanghai.aliyuncs.com
```

---

## 2. Architecture

### 2.1 Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| **Check frequency** | Every hour | Certs don't change faster than that; avoids false alarms from transient network issues |
| **Execution host** | infra-boss on Mac/Orbstack | Has network access to all targets; central observability lives on this cluster |
| **Data store** | ClickHouse (existing `kyb` database) | Already the central observability sink; Grafana reads from here |
| **Alert delivery** | Grafana Alerting + Feishu | Existing Grafana already sends to Feishu; no new notification channel needed |
| **Check method** | OpenSSL s_client | Available everywhere, no dependencies; parses x509 dates reliably |
| **Failure handling** | Report as `ERROR` status | A failed check (timeout, DNS failure) is itself actionable |

### 2.2 Data Flow

```
cron/hourly (or systemd timer)
      │
      ▼
check-tls-certs.sh (on infra-boss)
      │
      ├─── docker.xuanyuan.me:443  ─── openssl s_client
      ├─── git.leyantech.com:443    ─── openssl s_client
      ├─── registry.cn-shanghai.aliyuncs.com:443  ─── openssl s_client
      └─── [future: add more targets]
      │
      ▼
curl POST to ClickHouse (port 8123)
      │
      ▼
kyb.tls_cert_checks table
      │
      ▼
Grafana dashboard + alerts
      │
      ▼
Feishu notification (30/14/7 day thresholds)
```

### 2.3 Service Map

```
┌─────────────────────────────────────────┐
│  Mac/Orbstack (super-boss)              │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  infra-boss container           │    │
│  │                                 │    │
│  │  check-tls-certs.sh (hourly) ───┼───►│ ClickHouse
│  │                                 │    │  (kyb.tls_cert_checks)
│  │  Docker socket (host check)     │    │
│  └─────────────────────────────────┘    │
│                                         │
│  Grafana ─── reads CK ─── alerts ──► Feishu
└─────────────────────────────────────────┘
```

---

## 3. Check Script

### 3.1 Script: `/home/dev/.kyb/bin/check-tls-certs.sh`

```bash
#!/bin/bash
# check-tls-certs.sh - Check TLS certificate expiry for all infra services
# Runs from infra-boss container. Writes results to ClickHouse.
#
# Usage: check-tls-certs.sh
#   or:  CHECK_ONLY=1 check-tls-certs.sh   # dry-run, print to stdout

set -euo pipefail

CK_HOST="${CK_HOST:-host.orb.internal}"
CK_PORT="${CK_PORT:-8123}"
CK_DB="${CK_DB:-kyb}"
CK_TABLE="${CK_TABLE:-tls_cert_checks}"

# Targets: hostname port [label]
TARGETS=(
  "docker.xuanyuan.me 443 docker.xuanyuan.me"
  "git.leyantech.com 443 git.leyantech.com"
  "registry.cn-shanghai.aliyuncs.com 443 acr-registry"
  "github.com 443 github.com"
)

check_cert() {
  local host=$1 port=$2
  local out
  out=$(openssl s_client -connect "${host}:${port}" -servername "${host}" \
          </dev/null 2>/dev/null | openssl x509 -noout -dates -subject 2>/dev/null)
  echo "$out"
}

parse_dates() {
  local cert_output="$1"
  local not_before not_after

  not_before=$(echo "$cert_output" | grep '^notBefore=' | sed 's/^notBefore=//')
  not_after=$(echo "$cert_output" | grep '^notAfter=' | sed 's/^notAfter=//')

  # Convert to epoch seconds
  local epoch_before=0 epoch_after=0
  if [[ -n "$not_before" ]]; then
    epoch_before=$(date -d "$not_before" +%s 2>/dev/null || echo 0)
  fi
  if [[ -n "$not_after" ]]; then
    epoch_after=$(date -d "$not_after" +%s 2>/dev/null || echo 0)
  fi

  echo "$epoch_before $epoch_after $not_before $not_after"
}

days_until_expiry() {
  local epoch_expiry=$1 now
  now=$(date +%s)
  if [[ "$epoch_expiry" -eq 0 ]]; then
    echo "0"
    return
  fi
  echo $(( (epoch_expiry - now) / 86400 ))
}

main() {
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  for target in "${TARGETS[@]}"; do
    IFS=' ' read -r host port label <<< "$target"

    local status="OK"
    local days_left=0
    local epoch_after=0
    local not_before_str=""
    local not_after_str=""
    local issuer_str=""
    local error_msg=""

    # Run cert check with timeout (10s)
    local cert_out
    cert_out=$(timeout 10 openssl s_client -connect "${host}:${port}" \
                -servername "${host}" </dev/null 2>/dev/null)

    if [[ -z "$cert_out" ]]; then
      status="ERROR"
      error_msg="Connection failed or timed out"
    else
      local x509_out
      x509_out=$(echo "$cert_out" | openssl x509 -noout -dates -subject -issuer 2>/dev/null)

      if [[ -z "$x509_out" ]]; then
        status="ERROR"
        error_msg="TLS handshake succeeded but x509 parsing failed"
      else
        local parsed
        parsed=$(parse_dates "$x509_out")
        read -r epoch_before epoch_after nb_str na_str <<< "$parsed"

        epoch_after=$epoch_after
        not_before_str=$(echo "$cert_out" | openssl x509 -noout -dates 2>/dev/null \
                          | grep 'notBefore=' | sed 's/notBefore=//')
        not_after_str=$(echo "$cert_out" | openssl x509 -noout -dates 2>/dev/null \
                         | grep 'notAfter=' | sed 's/notAfter=//')
        issuer_str=$(echo "$x509_out" | grep '^issuer=' | sed 's/^issuer=//')

        days_left=$(days_until_expiry "$epoch_after")

        if [[ "$epoch_after" -eq 0 ]]; then
          status="ERROR"
          error_msg="Failed to parse expiry date"
        elif [[ "$days_left" -le 0 ]]; then
          status="EXPIRED"
          error_msg="Certificate expired $(( -days_left )) days ago"
        elif [[ "$days_left" -le 7 ]]; then
          status="CRITICAL"
        elif [[ "$days_left" -le 14 ]]; then
          status="WARNING"
        elif [[ "$days_left" -le 30 ]]; then
          status="NOTICE"
        fi
      fi
    fi

    if [[ -z "${not_before_str:-}" ]]; then not_before_str=""; fi
    if [[ -z "${not_after_str:-}" ]]; then not_after_str=""; fi
    if [[ -z "${issuer_str:-}" ]]; then issuer_str=""; fi
    if [[ -z "${error_msg:-}" ]]; then error_msg=""; fi

    if [[ "${CHECK_ONLY:-}" == "1" ]]; then
      printf "%-35s %-10s %4d days  %s  %s\n" \
        "$label" "$status" "$days_left" "$not_after_str" "$error_msg"
    else
      # Send to ClickHouse
      local json
      json=$(cat <<JSON
{
  "timestamp": "$timestamp",
  "target": "$label",
  "hostname": "$host",
  "port": $port,
  "status": "$status",
  "days_left": $days_left,
  "not_before": "${not_before_str:-}",
  "not_after": "${not_after_str:-}",
  "issuer": "${issuer_str:-}",
  "error": "${error_msg:-}"
}
JSON
)
      curl -s -X POST "http://${CK_HOST}:${CK_PORT}/?query=INSERT+INTO+${CK_DB}.${CK_TABLE}+FORMAT+JSONEachRow" \
        --data-binary "$json" \
        --noproxy '*' \
        --max-time 5 2>/dev/null || true
    fi
  done
}

main "$@"
```

### 3.2 Script Requirements

- **Dependencies:** `openssl`, `curl`, `bash`, `timeout` (from coreutils) -- all available in the kyb base image.
- **Timeouts:** 10-second connect timeout per target (via `timeout`). 5-second CK write timeout.
- **No proxy bypass for CK writes:** uses `--noproxy '*'` to avoid routing through sing-box.
- **Fail-open:** CK write failures are silently ignored with `|| true`.

### 3.3 Estimated Resource Usage

| Metric | Estimate |
|---|---|
| Execution time | ~5-15 seconds (4 targets × ~2-3s each) |
| Memory | Negligible (< 1 MB) |
| CK storage per check | ~300 bytes × 4 targets = ~1.2 KB |
| CK storage per year | ~1.2 KB × 8760 = ~10.5 MB |
| Network bandwidth | ~2 KB per check (inbound cert data) |
| Network outbound (to CK) | ~1.2 KB per check |

---

## 4. Alert Thresholds & Escalation

### 4.1 Alert States

| State | Days Left | Action |
|---|---|---|
| `OK` | > 30 | No action (logged for history) |
| `NOTICE` | 15-30 | Dashboard highlight, no notification |
| `WARNING` | 8-14 | Feishu notification to ops group |
| `CRITICAL` | 1-7 | Feishu @all, immediate action required |
| `EXPIRED` | ≤ 0 | Emergency -- service may be down |
| `ERROR` | N/A | Check failed (network, DNS, or timeout) |

### 4.2 Alert Rules (Grafana)

```sql
-- Rule 1: CRITICAL / EXPIRED (7 days or less)
SELECT
  target,
  days_left,
  status,
  timestamp
FROM kyb.tls_cert_checks
WHERE timestamp > now() - INTERVAL 2 HOUR
  AND status IN ('CRITICAL', 'EXPIRED')
ORDER BY days_left ASC;

-- Rule 2: WARNING (8-14 days)
SELECT
  target,
  days_left,
  status,
  timestamp
FROM kyb.tls_cert_checks
WHERE timestamp > now() - INTERVAL 2 HOUR
  AND status = 'WARNING'
ORDER BY days_left ASC;

-- Rule 3: ERROR (check failed)
SELECT
  target,
  error,
  timestamp
FROM kyb.tls_cert_checks
WHERE timestamp > now() - INTERVAL 2 HOUR
  AND status = 'ERROR'
ORDER BY timestamp DESC;
```

### 4.3 Escalation Policy

```
Days Left  State     Action                              Notify
───────────────────────────────────────────────────────────────
30+        OK        Log only                             None
15-30      NOTICE    Dashboard color: yellow              None (visible on Grafana)
8-14       WARNING   Feishu message                       #kyb-kindergarden (ops)
1-7        CRITICAL  Feishu @all + hourly reminder        #kyb-kindergarden
0-         EXPIRED   Emergency: manually investigate      #kyb-kindergarden + phone
N/A        ERROR     Investigate network/dns issue        #kyb-kindergarden
```

### 4.4 Rate Limit on Alerts

To avoid alert fatigue (e.g., every hourly check firing for a cert that is 6 days out):

- Grafana alert evaluates every hour
- `for: 2h` pending period before firing (requires 2 consecutive CRITICAL checks)
- Once fired, `repeat_interval: 24h` (don't re-notify daily for the same cert)

---

## 5. ClickHouse Schema

### 5.1 Table: `kyb.tls_cert_checks`

```sql
CREATE TABLE IF NOT EXISTS kyb.tls_cert_checks (
  timestamp   DateTime64(3) DEFAULT now(),
  target      LowCardinality(String),      -- friendly label: "docker.xuanyuan.me"
  hostname    String,                       -- actual hostname checked
  port        UInt16,                       -- port (usually 443)
  status      LowCardinality(String),       -- OK | NOTICE | WARNING | CRITICAL | EXPIRED | ERROR
  days_left   Int16,                        -- days until expiry (negative = expired)
  not_before  String,                       -- notBefore date string
  not_after   String,                       -- notAfter date string
  issuer      String,                       -- CA issuer name
  error       String                        -- error message (empty on success)
)
ENGINE = ReplacingMergeTree
ORDER BY (toDate(timestamp), target, hostname, port)
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

**Design Notes:**

- `ReplacingMergeTree` deduplicates by the same target within the same day. If the check runs
  twice in an hour on the same target, the last write wins. This keeps the table lean.
- 90-day TTL covers the maximum realistic cert lifetime (LE: 90 days). After 90 days the data
  is historical noise.
- `LowCardinality` on `target` and `status` because they have few unique values, optimizing
  storage and query speed.
- `days_left` is signed (`Int16`) to represent both future (+N) and past (-N) values.

### 5.2 Partitioning Strategy

- **Partition key:** `toYYYYMM(timestamp)` (monthly partitions)
  - ~300 KB per month → negligible, but standard practice for time-series tables
  - Enables efficient partition drop for TTL enforcement

```sql
-- Check partition sizes
SELECT
  partition,
  count() AS rows,
  formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
  formatReadableSize(sum(data_compressed_bytes)) AS compressed
FROM system.parts
WHERE table = 'tls_cert_checks'
GROUP BY partition
ORDER BY partition;
```

### 5.3 Useful Queries

```sql
-- Latest status for all targets
SELECT
  target,
  argMax(status, timestamp) AS latest_status,
  argMax(days_left, timestamp) AS latest_days_left,
  max(timestamp) AS last_checked
FROM kyb.tls_cert_checks
WHERE timestamp > now() - INTERVAL 1 DAY
GROUP BY target
ORDER BY latest_days_left ASC;

-- Expiry timeline (for dashboard graph)
SELECT
  toDate(timestamp) AS day,
  target,
  argMax(days_left, timestamp) AS days_left
FROM kyb.tls_cert_checks
WHERE timestamp > now() - INTERVAL 30 DAY
GROUP BY day, target
ORDER BY day, target;

-- Targets expiring within 30 days
SELECT
  target,
  days_left,
  not_after,
  issuer
FROM kyb.tls_cert_checks
WHERE timestamp > now() - INTERVAL 2 HOUR
  AND days_left > 0
  AND days_left <= 30
ORDER BY days_left ASC;

-- Check failure rate (last 24 hours)
SELECT
  target,
  countIf(status = 'ERROR') AS errors,
  count() AS total,
  round(errors / total * 100, 1) AS error_pct
FROM kyb.tls_cert_checks
WHERE timestamp > now() - INTERVAL 1 DAY
GROUP BY target
ORDER BY error_pct DESC;
```

---

## 6. Grafana Dashboard

### 6.1 Dashboard: "TLS Certificate Expiry"

**Panel 1: Expiry Countdown (Gauge / Stat)**

- Query: Latest `days_left` per target
- Visualization: Shared gauge, one metric per target
- Color thresholds: green (>30), yellow (15-30), orange (8-14), red (1-7), black (≤0)
- 自动将通知转发到飞书/Feishu

**Panel 2: Expiry Timeline (Graph / Time Series)**

- X-axis: time (last 30 days)
- Y-axis: `days_left`
- One line per target
- Horizontal reference lines at 30, 14, 7 days
- Useful for spotting trends (e.g., a cert that should have been renewed but wasn't
  will show a steadily declining line)

**Panel 3: Check Status Table**

- Columns: Target | Status | Days Left | Not Before | Not After | Issuer | Last Checked
- Color-coded by status
- Sortable by `days_left` ASC (always show soonest-expiring first)

**Panel 4: Error Rate (Stat / Time Series)**

- Count of ERROR status checks in last 24h
- Alert if any target has > 3 consecutive errors

**Panel 5: Cert Inventory Summary (Table)**

- All known targets with their metadata
- Updated metadata manually when adding new targets to the monitor

### 6.2 Feishu Alert Template

```
[${STATUS}] TLS Certificate Expiring: ${TARGET}

Certificate: ${TARGET}
Status:      ${STATUS}
Days Left:   ${DAYS_LEFT}
Expires:     ${NOT_AFTER}
Issuer:      ${ISSUER}
Last Check:  ${TIMESTAMP}

Action required: ${ACTION}

${ERROR}
```

### 6.3 Alert Condition Example

```json
{
  "alert": {
    "name": "TLS Cert Expiring Critical",
    "condition": "avg() OF query(A, 5m) IS BELOW 7",
    "execErrState": "alerting",
    "noDataState": "alerting",
    "for": "2h",
    "notifications": [
      {"uid": "feishu-kindergarden"}
    ],
    "message": "TLS cert {{ $labels.target }} expires in {{ $values }} days. Renew immediately."
  }
}
```

---

## 7. Deployment

### 7.1 Step 1: Create the ClickHouse Table

```bash
# From infra-boss or any host with CK access
clickhouse-client --host host.orb.internal --query "
CREATE TABLE IF NOT EXISTS kyb.tls_cert_checks (
  timestamp   DateTime64(3) DEFAULT now(),
  target      LowCardinality(String),
  hostname    String,
  port        UInt16,
  status      LowCardinality(String),
  days_left   Int16,
  not_before  String,
  not_after   String,
  issuer      String,
  error       String
)
ENGINE = ReplacingMergeTree
ORDER BY (toDate(timestamp), target, hostname, port)
TTL toDate(timestamp) + INTERVAL 90 DAY;
"
```

### 7.2 Step 2: Deploy the Script

```bash
# Copy script to the kyb bin directory
cp check-tls-certs.sh /home/dev/.kyb/bin/check-tls-certs.sh
chmod +x /home/dev/.kyb/bin/check-tls-certs.sh

# Verify it works
CHECK_ONLY=1 /home/dev/.kyb/bin/check-tls-certs.sh
```

### 7.3 Step 3: Schedule via infra-boss Cron

Inside the infra-boss container (Mac/Orbstack), set up a systemd timer or crontab:

**Option A: Infra-boss crontab (recommended for simplicity)**

```bash
# As root inside infra-boss:
echo '0 * * * * /home/dev/.kyb/bin/check-tls-certs.sh' > /etc/cron.d/tls-cert-check
chmod 644 /etc/cron.d/tls-cert-check
```

**Option B: Host crontab (if infra-boss doesn't have cron)**

```bash
# On the host (dongqs-mac):
0 * * * * docker exec infra-boss /home/dev/.kyb/bin/check-tls-certs.sh
```

**Option C: Patrol integration (run as part of existing 5-minute patrol)**

The check script is lightweight enough to run every patrol cycle. Add to the patrol checklist:

```bash
# In patrol script, before heartbeat write:
/opt/kyb/bin/check-tls-certs.sh
```

However, **Option A (hourly cron)** is recommended because:
- Certificates change on a timescale of days, not minutes
- Hourly is sufficient and avoids noise
- Patrol runs every 5 minutes and should stay focused on immediate health

### 7.4 Step 4: Create Grafana Dashboard

1. Open Grafana at `http://host.orb.internal:3000` (or `http://localhost:3000`)
2. Create new dashboard: "TLS Certificate Expiry"
3. Add data source: ClickHouse (should already be configured)
4. Add panels per Section 6

### 7.5 Step 5: Configure Alerts

1. In Grafana, navigate to Alerting > Alert rules
2. Create rules per Section 4.2
3. Configure Feishu contact point (use existing if configured)
4. Set notification policy to route to `#kyb-kindergarden`

### 7.6 Step 6: Test

```bash
# Dry-run the script
CHECK_ONLY=1 /home/dev/.kyb/bin/check-tls-certs.sh

# Force a CK write and verify
/home/dev/.kyb/bin/check-tls-certs.sh
clickhouse-client --host host.orb.internal \
  --query "SELECT target, status, days_left FROM kyb.tls_cert_checks WHERE timestamp > now() - INTERVAL 5 MINUTE"

# Simulate an expiring cert by temporarily setting CHECK_ONLY and manually POSTing
# (not necessary in production - the script handles it)
```

### 7.7 Check Script Health

Monitor the monitor itself:

```sql
-- Has the check run in the last 3 hours?
SELECT max(timestamp) AS last_check
FROM kyb.tls_cert_checks;

-- If last_check is > 3 hours old, the cron/systemd timer
-- or the infra-boss container itself may be down.
```

Add a Grafana alert for this: "TLS cert monitor last run > 3 hours ago".

---

## 8. Renewal Procedures

### 8.1 docker.xuanyuan.me (Primary Self-Managed Cert)

**Current:** Let's Encrypt via Google Trust Services, 90-day validity.

**Manual renewal:**

```bash
# SSH into the host serving docker.xuanyuan.me
# (This may be a reverse proxy or the registry itself, TBD)

# If using certbot:
certbot renew --cert-name docker.xuanyuan.me

# If using acme.sh:
acme.sh --renew -d docker.xuanyuan.me

# Reload the TLS-terminating service after renewal
docker exec kyb-infra-registry nginx -s reload  # if nginx
# or
docker restart kyb-infra-registry                # if registry handles TLS directly
```

**Verify renewal:**

```bash
check_cert docker.xuanyuan.me
# notAfter should now be ~90 days from today
```

### 8.2 Procedure for WARNING State (14 days left)

1. Check Grafana dashboard for affected target
2. Determine who manages the cert (self vs third-party)
3. For self-managed: follow renewal steps above
4. For third-party: notify the responsible team (e.g., GitLab IT for `git.leyantech.com`)
5. After renewal, wait for next hourly check or run manually
6. Confirm status returns to OK in Grafana

### 8.3 Procedure for CRITICAL State (7 days left)

1. Same as WARNING but elevated priority
2. Drop everything and renew
3. If renewal fails, investigate:
   - Is the ACME endpoint reachable?
   - Is the DNS record correct?
   - Is port 80/443 accessible from the renewing host?
   - Is the certbot/acme.sh config still valid?

### 8.4 Procedure for EXPIRED State (0 or negative days left)

1. Emergency -- service is likely down for TLS clients
2. Determine if the cert is fronted by a reverse proxy:
   - Yes: restart/reload the proxy (nginx, Caddy, HAProxy)
   - No: restart the service directly
3. If the cert simply wasn't renewed in time:
   - Run renewal immediately (may work if ACME client still has the key)
   - If ACME client has also expired (90-day limit), revoke and re-issue:
     ```bash
     certbot certonly --force-renewal -d docker.xuanyuan.me
     ```
4. After fixing, verify: `CHECK_ONLY=1 /opt/kyb/bin/check-tls-certs.sh`

---

## 9. Future: ACME Auto-Renewal

### 9.1 Desired State

The current `docker.xuanyuan.me` cert is 90-day Let's Encrypt but manually managed. The goal
is fully automated renewal.

### 9.2 Option A: certbot systemd timer

```bash
# On the host serving the cert:
systemctl enable certbot.timer  # auto-renewal twice daily
systemctl start certbot.timer
```

This auto-renews certs expiring within 30 days. Combined with our monitoring, we get:

- **Certbot timer:** auto-renewal, catches 95% of cases
- **TLS monitor (our script):** catches the 5% where certbot fails (port closed, DNS issue, etc.)

### 9.3 Option B: Caddy reverse proxy

Caddy automatically provisions and renews Let's Encrypt certs for its configured domains.
If we front `docker.xuanyuan.me` with Caddy, the cert is fully managed:

```bash
docker run -d \
  --name kyb-caddy \
  -p 443:443 \
  -p 80:80 \
  -v caddy-data:/data \
  caddy:2 \
  caddy reverse-proxy --from docker.xuanyuan.me --to kyb-registry-cache:5000
```

Caddy handles:
- Auto-provision on first request
- Auto-renewal 30 days before expiry
- Graceful reload on new cert

### 9.4 Recommended Path

1. **Short-term (this sprint):** Deploy the TLS monitor script + Grafana alerts
2. **Medium-term (next sprint):** Set up certbot auto-renew for `docker.xuanyuan.me`
3. **Long-term:** Evaluate Caddy as a unified TLS frontend for all external services

---

## Appendix A: Adding a New Target

To add a new TLS endpoint to monitoring:

1. Add the target to the `TARGETS` array in `check-tls-certs.sh`:
   ```bash
   TARGETS=(
     # ... existing targets ...
     "new-service.example.com 443 new-service"
   )
   ```
2. Update the dashboard if needed
3. Deploy and test

## Appendix B: Removing a Decommissioned Target

1. Remove the target from `TARGETS` array
2. Data remains in CK for 90 days (TTL handles cleanup)
3. Update dashboard to remove stale references

## Appendix C: Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| All targets show ERROR | Network issue in infra-boss | Check sing-box proxy, DNS resolution, outbound connectivity |
| Single target shows ERROR | Target unreachable | `openssl s_client -connect <host>:443` manually |
| CK insert failing | CK unreachable from infra-boss | `curl http://host.orb.internal:8123/?query=SELECT+1` |
| Script not found | Not deployed to infra-boss | `cp` the script into the container |
| openssl not found | Base image missing openssl | `apt-get update && apt-get install -y openssl` (or rebuild base) |

---

> **Summary:** An hourly Cron + OpenSSL + ClickHouse + Grafana pipeline that monitors
> all infra TLS certificates and alerts via Feishu at 30/14/7 days before expiry.
> Total resource cost: ~10 MB/year in ClickHouse storage.
> First self-managed target: `docker.xuanyuan.me` (expires 2026-08-05).

> /人◕ ‿‿ ◕人＼
