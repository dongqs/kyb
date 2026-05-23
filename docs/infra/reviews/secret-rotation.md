---
decision: 稍后做
---

# Design: Secret Rotation Monitoring

**Date:** 2026-05-23
**Status:** Design proposal
**Prerequisite reading:** `docs/infra/observability-design.md` (existing monitoring stack),
`docs/infra/5min-patrol-guide.md` (patrol integration),
`docs/infra/multi-cluster-boss-architecture.md` (boss-mode infra context).

---

## 1. Problem

Secrets and credentials in the infra stack are provisioned once and rarely revisited.
The following failure modes are invisible without proactive rotation monitoring:

| Failure Mode | Detection | Consequence |
|---|---|---|
| API token expires | Credential rejected by upstream service | Service outage until token is manually refreshed |
| TLS certificate expires | SSL handshake failure | All HTTPS traffic to service fails |
| Service account credential stale | Auth failure on CI/CD pipeline | Deployments blocked, CI red |
| Personal access token (PAT) stale | Git push/clone rejected | Automation pipeline stuck |
| Database password never rotated | Audit trail check | Compliance violation, elevated breach risk |
| SSH key never rotated | Key discovery / leak | Persistent unauthorized access if key leaked |
| Rotation SLA breached | Age > policy threshold | Compliance violation, blast radius too wide |

Without tracking credential age and expiry, each secret is a ticking time bomb
discovered only when it actually fails — causing an operational incident that
could have been prevented by a scheduled rotation.

### Scope

Secrets tracked in this design:

| Category | Examples | Rotation Policy |
|---|---|---|
| API tokens | Feishu app token, OpenAI API key, Tailscale auth key | 90 days |
| TLS certificates | Let's Encrypt, internal CA certs | 90 days (auto-renewed, track age) |
| CI/CD tokens | GitLab deploy tokens, PATs | 180 days |
| Database credentials | PostgreSQL passwords, ClickHouse passwords | 180 days |
| SSH keys | Deploy keys, host keys | 365 days |
| Cloud provider keys | Aliyun AK/SK, Orbstack machine tokens | 90 days |
| Service-to-service tokens | Docker registry auth, Vector-to-ClickHouse auth | 180 days |

---

## 2. Metrics to Collect

### 2.1 Credential Age

The fundamental metric: how long since each credential was last rotated.

```promql
# Pseudo-metric: tracked via external exporter or static config file
secret_age_days{secret="feishu_app_token", category="api"} 127
secret_age_days{secret="openai_api_key", category="api"} 45
secret_age_days{secret="gitlab_deploy_token", category="cicd"} 210
```

Labels:
- `secret` — logical name (e.g. `feishu_app_token`, `pg_password_kindergarden`)
- `category` — `api`, `tls`, `cicd`, `database`, `ssh`, `cloud`, `service`
- `environment` — `production`, `staging`, `dev`
- `rotation_policy_days` — target max age in days (static label)
- `last_rotated` — ISO 8601 timestamp of last rotation (gauge as epoch seconds)
- `expires_at` — ISO 8601 timestamp of absolute expiry, if known (gauge as epoch seconds)

### 2.2 Days Until Expiry (Absolute Expiry)

For secrets with a hard expiry date (TLS certs, some API tokens):

```promql
secret_expiry_days_remaining{secret="letsencrypt_boss", category="tls"} 32
```

**Negative values mean the secret is already expired** — highest priority alert.

### 2.3 Rotation Compliance Ratio

Percentage of secrets within their rotation policy window:

```promql
# Total secrets
count(secret_age_days)

# Compliant secrets
count(secret_age_days{secret_age_days < rotation_policy_days})
```

A compliance ratio < 90% triggers a review alert.

### 2.4 Rotation Event Log

Each rotation should emit a structured event:

| Field | Example |
|---|---|
| `event_time` | 2026-05-23T10:00:00Z |
| `secret_name` | `feishu_app_token` |
| `rotator` | `kyb rotate feishu-app-token` |
| `previous_age_days` | 127 |
| `new_age_days` | 0 |
| `status` | `success` / `failure` |
| `failure_reason` | `upstream_api_error` (if status=failure) |

These events are stored in ClickHouse for trend analysis.

### 2.5 Key Thresholds

| Level | Age vs Policy | Expiry Remaining | Action |
|---|---|---|---|
| INFO | < 50% of policy | > 30 days | Normal, no action |
| NOTICE | 50-75% of policy | 14-30 days | Plan rotation |
| WARN | 75-90% of policy | 7-14 days | Schedule rotation |
| ALERT | 90-100% of policy | 1-7 days | Rotate within 24h |
| CRIT | > 100% of policy | Expired / negative | Rotate immediately |

---

## 3. Collection Architecture

### 3.1 Multi-Method Strategy

No single tool can discover all secrets. Use a layered approach:

```
┌──────────────────────────────────────────────────────────────┐
│                  Secret Age Registry (source of truth)        │
│  ~/.kyb/secrets/registry.yml  (tracked but values redacted)  │
│  git-crypt or sops encrypted at rest                         │
├──────────────────────────────────────────────────────────────┤
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐  │
│  │ Static Config  │  │ Certificate    │  │ Discovery      │  │
│  │ (manual entry) │  │ Transparency   │  │ Scripts        │  │
│  │                │  │ (cert expiry)  │  │ (env vars,     │  │
│  │ Add secret +   │  │                │  │  config files, │  │
│  │ rotation date  │  │ Auto-check     │  │  docker envs)  │  │
│  │ when created   │  │ TLS certs via  │  │                │  │
│  │                │  │ openssl/certbot│  │ Semi-auto scan │  │
│  └────────────────┘  └────────────────┘  └────────────────┘  │
│           │                  │                   │            │
│           ▼                  ▼                   ▼            │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │           secret-rotation-exporter (Prometheus)           │ │
│  │                                                           │ │
│  │  Exposes:                                                  │ │
│  │    secret_age_days{secret, category, policy_days}          │ │
│  │    secret_expiry_days_remaining{secret, category}          │ │
│  │    secret_rotation_info{secret, category, ...}             │ │
│  └──────────────────────────────────────────────────────────┘ │
│                              │                                 │
│                              ▼                                 │
│                    Prometheus + Alertmanager                   │
│                              │                                 │
│                              ▼                                 │
│                    Grafana Dashboard                         │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 Secret Age Registry

Source of truth for credential metadata. Lives in the `kyb` config directory:

```yaml
# ~/.kyb/secrets/registry.yml
# secret values go in vault/sops, this is metadata only
secrets:
  - name: feishu_app_token
    category: api
    environment: production
    last_rotated: "2026-01-17T10:00:00Z"
    expires_at: null  # no hard expiry, rotated by policy
    rotation_policy_days: 90
    owner: "infra-team"
    notes: "Feishu openapi.app_token for cc-connect"

  - name: openai_api_key
    category: api
    environment: production
    last_rotated: "2026-04-08T08:00:00Z"
    expires_at: null
    rotation_policy_days: 90
    owner: "infra-team"

  - name: letsencrypt_boss
    category: tls
    environment: production
    last_rotated: "2026-03-15T00:00:00Z"
    expires_at: "2026-06-13T00:00:00Z"
    rotation_policy_days: 90  # auto-renewed by certbot, monitored post-renewal
    owner: "infra-team"

  - name: gitlab_deploy_token_kyb
    category: cicd
    environment: production
    last_rotated: "2024-10-20T00:00:00Z"
    expires_at: null  # GitLab PATs have no max expiry unless set
    rotation_policy_days: 180
    owner: "infra-team"
    status: "overdue"  # manual override for known-stale secrets
```

### 3.3 Rotation Exporter (Prometheus)

A lightweight Python/Go exporter that reads the registry and exposes metrics:

**Metric endpoints:**

```
# HELP secret_age_days Age of secret in days since last rotation
# TYPE secret_age_days gauge
secret_age_days{secret="feishu_app_token",category="api",environment="production",owner="infra-team",rotation_policy_days="90"} 127

# HELP secret_expiry_days_remaining Days until secret hard expiry (infinity if none)
# TYPE secret_expiry_days_remaining gauge
secret_expiry_days_remaining{secret="letsencrypt_boss",category="tls",environment="production"} 32

# HELP secret_rotation_info Static metadata about each secret
# TYPE secret_rotation_info gauge
secret_rotation_info{secret="feishu_app_token",category="api",last_rotated="2026-01-17T10:00:00Z",expires_at="",policy_days="90",owner="infra-team",status="active"} 1
```

**Implementation sketch:**

```python
#!/usr/bin/env python3
"""secret-rotation-exporter: Prometheus exporter for secret rotation metadata."""
import os
import yaml
import time
from datetime import datetime, timedelta, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

REGISTRY_PATH = os.path.expanduser("~/.kyb/secrets/registry.yml")

def load_registry():
    with open(REGISTRY_PATH) as f:
        return yaml.safe_load(f)

def compute_metrics(registry):
    now = datetime.now(timezone.utc)
    lines = [
        '# HELP secret_age_days Age of secret since last rotation',
        '# TYPE secret_age_days gauge',
        '# HELP secret_expiry_days_remaining Days until hard expiry',
        '# TYPE secret_expiry_days_remaining gauge',
        '# HELP secret_rotation_info Static metadata for each secret',
        '# TYPE secret_rotation_info gauge',
    ]
    for s in registry.get('secrets', []):
        name = s['name']
        cat = s['category']
        env = s.get('environment', 'unknown')
        owner = s.get('owner', 'unknown')
        policy = s.get('rotation_policy_days', 365)
        labels = f'secret="{name}",category="{cat}",environment="{env}",owner="{owner}",rotation_policy_days="{policy}"'

        # age
        last = datetime.fromisoformat(s['last_rotated'])
        age_days = (now - last).days
        lines.append(f'secret_age_days{{{labels}}} {age_days}')

        # expiry
        expires = s.get('expires_at')
        if expires:
            exp = datetime.fromisoformat(expires)
            remaining = (exp - now).days
        else:
            remaining = float('inf')
        lines.append(f'secret_expiry_days_remaining{{{labels}}} {remaining}')

        # info
        status = s.get('status', 'active')
        info_labels = f'{labels},last_rotated="{s["last_rotated"]}",expires_at="{expires or ""}",status="{status}"'
        lines.append(f'secret_rotation_info{{{info_labels}}} 1')

    return '\n'.join(lines) + '\n'

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            registry = load_registry()
            metrics = compute_metrics(registry)
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write(metrics.encode())
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    port = int(os.environ.get('EXPORTER_PORT', 9188))
    server = HTTPServer(('0.0.0.0', port), MetricsHandler)
    print(f'secret-rotation-exporter on :{port}')
    server.serve_forever()
```

Deployment: run as a sidecar container or systemd timer, exposed on port `9188`.

### 3.4 Certificate Expiry Detection (TLS)

For TLS certificates, use `openssl` in a cron script rather than relying on manual
registry entries:

```bash
#!/bin/bash
# ~/.kyb/bin/cert-expiry-check
# Extracts expiry dates from certificate files.

set -euo pipefail

CERTS_DIR="${1:-/etc/letsencrypt/live}"
NOW_EPOCH=$(date +%s)

for CERT_DIR in "$CERTS_DIR"/*/; do
    CERT_FILE="${CERT_DIR}cert.pem"
    if [ ! -f "$CERT_FILE" ]; then
        continue
    fi
    DOMAIN=$(basename "$CERT_DIR")
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)
    REMAINING_DAYS=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    echo "cert_expiry_days_remaining{domain=\"$DOMAIN\"} $REMAINING_DAYS"
done
```

### 3.5 Lightweight Patrol Script

For environments without Prometheus, a single check script runs via cron:

`~/.kyb/bin/secret-rotation-check`:

```bash
#!/bin/bash
set -euo pipefail

REGISTRY="${HOME}/.kyb/secrets/registry.yml"
NOW_EPOCH=$(date +%s)

if [ ! -f "$REGISTRY" ]; then
    echo "CRITICAL: Secret registry not found at $REGISTRY"
    exit 2
fi

# Parse with yq (or python)
SECRETS=$(python3 -c "
import yaml, sys, json
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
with open('${REGISTRY}') as f:
    reg = yaml.safe_load(f)
results = []
for s in reg.get('secrets', []):
    last = datetime.fromisoformat(s['last_rotated'])
    age_days = (now - last).days
    policy = s.get('rotation_policy_days', 365)
    pct = age_days / policy * 100
    name = s['name']
    expires = s.get('expires_at')
    exp_remaining = None
    if expires:
        exp = datetime.fromisoformat(expires)
        exp_remaining = (exp - now).days
    results.append({
        'name': name,
        'age_days': age_days,
        'policy_days': policy,
        'pct': pct,
        'exp_remaining': exp_remaining,
        'status': s.get('status', 'active')
    })
print(json.dumps(results, indent=2))
")

# Evaluate each secret
WARN=false
CRIT=false
MESSAGE=""

while IFS=$'\t' read -r name age pct exp_rem status; do
    EXPIRY_WARN=""
    if [ "$exp_rem" != "null" ] && [ "$exp_rem" -lt 14 ] 2>/dev/null; then
        EXPIRY_WARN=" (expires in ${exp_rem}d)"
        CRIT=true
    fi

    if [ "$(echo "$pct > 100" | bc)" -eq 1 ]; then
        MESSAGE="${MESSAGE}  CRIT: ${name} age=${age}d exceeds policy (${age}d)${EXPIRY_WARN}\n"
        CRIT=true
    elif [ "$(echo "$pct > 90" | bc)" -eq 1 ]; then
        MESSAGE="${MESSAGE}  WARN: ${name} age=${age}d at ${pct}% of policy${EXPIRY_WARN}\n"
        WARN=true
    elif [ "$(echo "$pct > 75" | bc)" -eq 1 ]; then
        MESSAGE="${MESSAGE}  NOTICE: ${name} age=${age}d at ${pct}% of policy${EXPIRY_WARN}\n"
    fi
done < <(echo "$SECRETS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for s in data:
    print(f\"{s['name']}\t{s['age_days']}\t{s['pct']}\t{s['exp_remaining']}\t{s['status']}\")
")

if [ -n "$MESSAGE" ]; then
    echo -e "Secret Rotation Check:\n$MESSAGE"
fi

if $CRIT; then
    exit 2
elif $WARN; then
    exit 1
else
    echo "All secrets within rotation policy."
    exit 0
fi
```

Exit codes:
- `0` — all secrets within policy, no expiry warnings
- `1` — any secret > 90% of rotation policy or expiring < 14 days
- `2` — any secret past policy, expired, or expiry in < 7 days

---

## 4. Alert Rules

### 4.1 Prometheus Alertmanager Rules

```yaml
groups:
  - name: secret_rotation
    rules:
      # Secret past rotation policy
      - alert: SecretRotationOverdue
        expr: secret_age_days > on(secret) secret_rotation_info * on(secret) group_left(rotation_policy_days) rotation_policy_days
        for: 1d  # allow 1 day grace for ongoing rotation
        labels:
          severity: critical
        annotations:
          summary: "Secret {{ $labels.secret }} is past rotation policy ({{ $value | humanize }}d, policy {{ $labels.rotation_policy_days }}d)"

      # Secret near rotation policy (90%+)
      - alert: SecretRotationDue
        expr: secret_age_days > on(secret) secret_rotation_info * on(secret) group_left(rotation_policy_days) rotation_policy_days * 0.9
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Secret {{ $labels.secret }} is {{ $value | humanize }}d old ({{ $labels.rotation_policy_days }}d policy) — rotate soon"

      # Certificate expiring within 14 days
      - alert: CertExpirySoon
        expr: cert_expiry_days_remaining < 14
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Certificate {{ $labels.domain }} expires in {{ $value }} days"

      # Certificate expired
      - alert: CertExpired
        expr: cert_expiry_days_remaining < 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Certificate {{ $labels.domain }} has expired!"

      # Compliance ratio dropped
      - alert: RotationComplianceLow
        expr: |
          (
            count(secret_age_days) -
            count(secret_age_days{secret_age_days <= on(secret) secret_rotation_info * on(secret) group_left(rotation_policy_days) rotation_policy_days})
          ) / count(secret_age_days) > 0.1
        for: 1d
        labels:
          severity: warning
        annotations:
          summary: "Secret rotation compliance below 90% ({{ $value | humanize% }} non-compliant)"
```

### 4.2 Integration with 5-Min Patrol

Add a check step to `5min-patrol-guide.md`:

```
Secret rotation check → `secret-rotation-check`
- 0 green = all secrets within policy
- 1 yellow = approaching policy limit (>90%) or cert <14d
- 2 red = past policy, expired cert, or compliance <90%
```

### 4.3 Feishu Alert Routing

| Alert | Severity | Channel |
|---|---|---|
| Secret past rotation policy | P0 | Feishu group @all + TTS notify |
| Certificate expired | P0 | Feishu group @all + TTS notify |
| Secret > 90% of policy | P1 | Feishu group |
| Certificate < 14 days | P1 | Feishu group |
| Compliance < 90% | P2 | Feishu group (daily digest) |
| Secret > 75% of policy | P3 | Feishu group (quiet, plan reminder) |

### 4.4 Boss Mode Healthcheck

The boss agent's environment healthcheck should include:

```bash
# Check secret rotation compliance
secret-rotation-check
case $? in
  0) echo "Secret rotation: OK";;
  1) echo "Secret rotation: WARN — approaching policy limits";;
  2) echo "Secret rotation: CRITICAL — rotate immediately";;
esac
```

---

## 5. Rotation Workflow

### 5.1 Standard Rotation Procedure

Each secret type has a dedicated rotation command or rec:

| Secret Type | Rotation Method | Canonical Tool |
|---|---|---|
| Feishu app token | Regenerate via Feishu Open API, update env file | `kyb rotate feishu-app-token` |
| TLS cert (Let's Encrypt) | `docker exec certbot renew` | certbot |
| GitLab PAT | Regenerate via GitLab UI or `glab` | glab CLI |
| PostgreSQL password | `ALTER USER ... PASSWORD` | `kyb rotate pg-password` |
| SSH key | `ssh-keygen -t ed25519 -f newkey`, deploy pubkey | Manual + script |
| Cloud provider key | Rotate via cloud provider CLI/console | Provider CLI |

### 5.2 Registry Update After Rotation

After any rotation, update the registry:

```bash
# ~/.kyb/bin/secret-rotate-registry
# Usage: secret-rotate-registry <secret-name>
# Updates last_rotated to now, clears any "overdue" status.

python3 -c "
import yaml, sys, json
from datetime import datetime, timezone

registry_path = '${HOME}/.kyb/secrets/registry.yml'
secret_name = sys.argv[1]
now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

with open(registry_path) as f:
    reg = yaml.safe_load(f)

for s in reg['secrets']:
    if s['name'] == secret_name:
        s['last_rotated'] = now
        s.pop('status', None)
        print(f'Updated {secret_name}: last_rotated={now}')
        break
else:
    print(f'Error: secret {secret_name} not found in registry')
    sys.exit(1)

with open(registry_path, 'w') as f:
    yaml.dump(reg, f, default_flow_style=False)
" "$1"
```

### 5.3 Rotation Audit Log (ClickHouse)

Each rotation emits an event to ClickHouse:

```sql
CREATE TABLE infra.secret_rotation_log (
    event_time      DateTime64(3) DEFAULT now(),
    secret_name     String,
    rotator         String,
    previous_age_days UInt16,
    status          LowCardinality(String),  -- success / failure
    failure_reason  String DEFAULT '',
    triggered_by    String DEFAULT 'scheduled'  -- scheduled / manual / alert
) ENGINE = MergeTree
ORDER BY (event_time, secret_name)
TTL event_time + INTERVAL 365 DAY
```

---

## 6. Initial Inventory

First step: enumerate all secrets currently in use. Audit targets:

| Location | What to Check |
|---|---|
| `~/.kyb/config.yml` | Any hardcoded tokens or passwords |
| `~/.config/kyb/config.yml` | Project-specific credentials |
| Docker `.env` files | Environment variable secrets |
| Docker Compose files | Inline `environment:` secrets |
| GitLab CI variables | `glab api projects/:id/variables` |
| Fly.io secrets | `fly secrets list` |
| Tailscale auth keys | `tailscale status` / key list |
| TLS cert directories | `/etc/letsencrypt/live/*`, docker cert volumes |
| SSH authorized_keys | Critical deploy keys |
| `~/.netrc`, `~/.git-credentials` | Hardcoded auth |

---

## 7. Alert Fatigue Prevention

| Guard | Implementation |
|---|---|
| Past-policy alert has 1d grace | Prometheus `for: 1d` — allows in-progress rotation |
| Compliance alert only daily | `for: 1d` — single daily notification, not per-scrape |
| Cert expiry has staged alerts | WARN at 14d, CRIT at 0d — no overnight escalations |
| Manual `status: overdue` override | Secrets known to be stale but awaiting rotation don't re-alert |
| New secrets get full policy window | Default `last_rotated = now` on creation |
| Rotation events tracked in CK | Audit trail for "was it rotated?" without re-alerting |

---

## 8. Implementation Plan

| Step | What | Who | ETA |
|---|---|---|---|
| 1 | Inventory: enumerate all secrets across infra locations | Ops | 2h |
| 2 | Create `~/.kyb/secrets/registry.yml` with initial entries | Ops | 30m |
| 3 | Write `secret-rotation-exporter` (Python), deploy as container | Ops | 1h |
| 4 | Write `cert-expiry-check` script for TLS auto-discovery | Ops | 30m |
| 5 | Write `secret-rotation-check` patrol script | Ops | 30m |
| 6 | Write `secret-rotate-registry` update tool | Ops | 15m |
| 7 | Add secret rotation step to 5-min patrol guide | Ops | 15m |
| 8 | Create Grafana dashboard (secret age overview, compliance gauge) | Ops | 1h |
| 9 | Configure Prometheus alert rules | Ops | 30m |
| 10 | Create ClickHouse table `infra.secret_rotation_log` | Ops | 15m |
| 11 | Rotate first overdue secret as validation run | Ops | 30m |
| 12 | Document rotation runbook per secret type | Ops | 1h |

**Total: ~8h**

---

## 9. References

- [Prometheus Best Practices — Metric Naming](https://prometheus.io/docs/practices/naming/)
- [Let's Encrypt Certificate Monitoring](https://letsencrypt.org/docs/monitoring/)
- [GitLab API — Project Variables](https://docs.gitlab.com/ee/api/project_level_variables.html)
- [Feishu Open API — Tenant Access Token](https://open.feishu.cn/document/server-docs/authentication-management/access-token/tenant_access_token/internal)
- [sops — Secrets OPerationS](https://github.com/getsops/sops)
- [Grafana Dashboard — TLS Certificate](https://grafana.com/grafana/dashboards/13936-tls-certificate/)
