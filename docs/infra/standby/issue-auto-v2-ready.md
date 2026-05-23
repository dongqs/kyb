---
decision: 稍后做
---

# Issue Automation v2 — cc-connect Cron + Feishu Alerts + Auto-Priority

**Author:** kyb-infra-boss
**Date:** 2026-05-23
**Status:** Ready for implementation
**Prerequisites:**
- `docs/infra/designs/issue-automation.md` (v1 design)
- `docs/infra/reviews/review-issue-automation-E1.md` (cron reliability review)
- `docs/infra/reviews/review-issue-automation-E2.md` (GitLab API review)
- `docs/infra/reviews/review-issue-automation-E3.md` (curl script review)
- `docs/infra/reviews/feishu-delivery.md` (delivery tracking infra)
- `docs/infra/reviews/mention-response.md` (mention tracking infra)

---

## 1. Problem

v1 (`docs/infra/designs/issue-automation.md`) solves the basic problem: detect new GitLab issues and notify the feishu group. But three gaps remain:

| Gap | Impact |
|-----|--------|
| **No alerting on automation failure** | If `check-issues.sh` crashes or the cron doesn't fire, nobody knows. Issue detection goes dark until a user reports "I created an issue 2 hours ago and nobody saw it." |
| **No priority classification** | Every issue gets the same notification, regardless of severity (crash vs feature request). Ops can't triage at a glance. P0 issues mixed with P4 feature requests in the same chat. |
| **No delivery confirmation** | The feishu notification is fire-and-forget. If cc-connect's send fails or feishu silently drops the message, the issue is effectively lost (created but nobody told). |

### 1.1 Scope

v2 adds three capabilities on top of v1's cc-connect cron foundation:

1. **Feishu alerts** on automation pipeline health (cron heartbeat, API errors, script crashes)
2. **Auto-priority classification** from labels, content, author, and project metadata
3. **Delivery confirmation** via existing feishu delivery tracking (`feishu-delivery.md`)

v2 does NOT change:
- Polling mechanism (still cc-connect cron, every 10 minutes)
- GitLab API endpoint choice (still project-level `GET /api/v4/projects/:id/issues`)
- State file persistence (`/data/issue-automation/last_iid`)
- The curl+jq script approach (hardened per E1/E2/E3 review findings)

---

## 2. High-Level Architecture

```
                         GitLab
                           │
              ┌────────────┼────────────┐
              │  GET /api/v4/projects/  │
              │  :id/issues?           │
              │  updated_after=...     │
              └────────────┬───────────┘
                           │
                    ┌──────▼───────┐
                    │ check-issues │  ← cc-connect cron (*/10 * * * *)
                    │ .sh          │
                    └──────┬───────┘
                           │
              ┌────────────┼──────────────┐
              │            │              │
         ┌────▼───┐  ┌────▼────┐  ┌──────▼──────┐
         │ State  │  │ Priority│  │ Notification │
         │ File   │  │ Engine  │  │ Router       │
         │ last_i │  │ label + │  │ P0→P1: now   │
         │ d      │  │ content │  │ P2: batch    │
         └────────┘  │ + author│  │ P3→P4: daily │
                     └────┬────┘  └──────┬──────┘
                          │              │
                          │        ┌─────▼──────┐
                          │        │ cc-connect  │
                          │        │ send →      │
                          │        │ feishu      │
                          │        └─────┬──────┘
                          │              │
                          │        ┌─────▼──────┐
                          │        │ Delivery   │
                          │        │ Tracker    │
                          │        │ (feishu-   │
                          │        │ delivery   │
                          │        │ .md)       │
                          │        └────────────┘
                          │
                    ┌─────▼──────┐
                    │ Heartbeat  │
                    │ /data/     │
                    │ issue-auto │
                    │ mation/    │
                    │ heartbeat  │
                    └────────────┘
```

### 2.1 Data Flow (Complete Cycle)

```
1. Cron fires (every 10 minutes)
2. check-issues.sh:
   a. Read last_iid from state file
   b. GET /api/v4/projects/:id/issues?updated_after=...&per_page=100
   c. Parse response with jq
   d. For each new issue (iid > last_iid):
      i.   Run Priority Engine → get priority (P0-P4)
      ii.  Determine notification urgency from priority
      iii. If P0/P1: send feishu notification immediately via cc-connect
      iv.  If P2: queue for next batch (every 30min)
      v.   If P3/P4: queue for daily summary
   e. Write new last_iid atomically (write to tmp, mv)
   f. Update heartbeat timestamp
3. Feishu notification includes:
   - Priority badge (P0-P4 with color coding)
   - Issue title, link, author, labels
   - Auto-priority reason (which signal drove the priority)
4. Delivery tracker records notification delivery status
5. If delivery fails for P0/P1: retry once, then alert ops channel
```

---

## 3. Auto-Priority Engine

### 3.1 Priority Levels

| Level | Label | SLA | Notification | Color |
|-------|-------|-----|-------------|-------|
| P0 | 🔴 Critical | < 15min response | Immediate + alert tracking | Red |
| P1 | 🟠 High | < 1h response | Immediate | Orange |
| P2 | 🟡 Medium | < 4h response | Next batch (30min) | Yellow |
| P3 | 🔵 Low | < 24h response | Daily summary | Blue |
| P4 | ⚪ Wishlist | Best effort | Daily summary | Gray |

### 3.2 Priority Signals

Priority is computed from multiple signals, each producing a base priority and a modifier:

#### Signal 1: Labels (strongest signal)

```yaml
label_priority_map:
  "severity::critical":  P0
  "severity::high":      P1
  "severity::medium":    P2
  "severity::low":       P3
  "type::bug":           P1  # bugs are always at least P1
  "type::security":      P0
  "type::performance":   P2
  "type::feature":       P3
  "area::production":    P1  # production-related
  "area::deployment":    P2
  "priority::immediate": P0
  "priority::urgent":    P1
  "priority::high":      P1
  "priority::normal":    P2
  "priority::low":       P3
```

If multiple labels match, the **highest priority** wins.

#### Signal 2: Content Analysis (weaker signal, regex-based)

```yaml
keyword_priority_boost:
  # P0 triggers: any keyword → force P0
  force_p0:
    - "production down"
    - "完全不可用"
    - "数据丢失"
    - "data loss"
    - "security breach"
    - "outage"
    - "crash.*all"
    - "all.*crash"

  # P1 boost: raise priority by 1 level
  boost_p1:
    - "crash"
    - "崩溃"
    - "500 error"
    - "cannot deploy"
    - "blocked"
    - "blocking"
    - "urgent"
    - "紧急"
    - "立刻"
    - "broken"
    - "regression"

  # P2 boost: raise priority by 1 level
  boost_p2:
    - "slow"
    - "延迟"
    - "timeout"
    - "error"
    - "failed"
    - "失败"
    - "warning"
    - "提醒"
```

Boost rules: a keyword match raises the label-derived priority by 1 level (e.g., P2 → P1). `force_p0` overrides everything and sets P0 regardless of labels.

#### Signal 3: Author Context

```yaml
author_priority:
  # Known team members get a +1 priority boost (faster response to internal issues)
  team_members:
    - "aoyama"
    - "kyb-core-team-*"  # glob pattern
  team_boost: -1  # reduce P level number by 1 (P2 → P1)

  # External reporters get +1 (they're less familiar with triage, need faster response)
  external_reporter_boost: false  # disabled in v2, may enable in v3

  # Bot accounts: no priority boost
  bot_accounts:
    - "gitlab-bot"
    - "renovate-bot"
    - "dependabot"
```

#### Signal 4: Project Context

```yaml
project_priority:
  "kyb/infra/core":     P1  # core infra projects
  "kyb/infra/tooling":  P2  # tooling/instrumentation
  "kyb/app":            P2  # application code
  "kyb/docs":           P3  # documentation
  "kyb/experimental":   P3  # experimental projects
```

The project signal provides a **base priority** if no labels exist. If labels exist, project is a tiebreaker.

#### Signal 5: Time Decay (Aging Bastard)

If an issue remains open past its SLA without a `priority::triaged` label, its priority escalates:

```
P4 → P3 after 7 days
P3 → P2 after 3 days
P2 → P1 after 1 day (if SLA is 4h, escalates after 24h)
P1 remains P1 (already escalated)
P0 remains P0 (already highest)
```

Time decay applies to the **stored priority** value, which is re-computed on each poll cycle. This means an issue that was originally P3 (feature request) but hasn't been triaged in 3 days becomes P2.

### 3.3 Priority Decision Logic

```
Input: issue (title, description, labels, author, project, created_at)
Output: priority_level (P0-P4), signals_used [list], confidence (0.0-1.0)

Algorithm:
1. Start with DEFAULT_PRIORITY = P3

2. Labels → label_priority
   For each label in issue.labels:
     if label in label_priority_map:
       label_priority = max(label_priority, label_priority_map[label])

3. Content analysis → content_boost
   For each keyword in force_p0:
     if keyword matches in (title + description):
       return P0, ["force_p0:keyword"], 1.0
   For each keyword in boost_p1:
     if keyword matches:
       content_boost = max(content_boost, 1)
   For each keyword in boost_p2:
     if keyword matches:
       content_boost = max(content_boost, 2)

4. Author analysis → author_boost
   if author in team_members:
     author_boost = -1  (lower P number = higher priority)

5. Project → project_base
   if project in project_priority:
     project_base = project_priority[project]

6. Combine:
   priority = min(project_base, label_priority)  # whichever is higher
   priority = max(P0, priority - content_boost)   # apply content boost (never go above P0)
   priority = max(P0, priority - (author_boost if author_boost else 0))

7. Time decay (re-computed each poll):
   age_days = now - issue.created_at
   if not "priority::triaged" in issue.labels:
     priority = apply_time_decay(priority, age_days)

8. Return priority + trace of signals used
```

### 3.4 Priority Store

The computed priority is stored alongside `last_iid` in the state directory, so it survives container restarts and isn't re-computed from scratch on each poll (which would cause priority "jitter" as signals change):

```
/data/issue-automation/
├── last_iid              # last processed issue IID (from v1)
├── heartbeat             # timestamp of last successful poll (new)
├── priorities.json       # { "iid": { "priority": "P1", "computed_at": "...", "signals": [...] } }
└── priority_history.jsonl  # append-only log (for analysis)
```

**State file format — `priorities.json`:**

```json
{
  "42": {
    "priority": "P1",
    "computed_at": "2026-05-23T14:30:00Z",
    "signals": ["label:severity::high", "content:crash", "team_member_boost"],
    "version": 2
  },
  "41": {
    "priority": "P3",
    "computed_at": "2026-05-22T10:00:00Z",
    "signals": ["label:type::feature", "project_base"],
    "version": 2
  }
}
```

The priority store is a **cache**, not a source of truth. If deleted, priorities are re-computed on the next poll. This keeps recovery simple.

---

## 4. Feishu Alerts for Automation Health

### 4.1 Alert Channels

| Channel | Purpose | Severity |
|---------|---------|----------|
| Ops Feishu Group | Day-to-day automation health | P2-P3 |
| PagerDuty | Automation pipeline is down | P1 |
| Grafana Dashboard | Historical trends, silence periods | Info |

### 4.2 Alert Rules

| Rule | Condition | Severity | Channel | Cooldown |
|------|-----------|----------|---------|----------|
| **CronHeartbeatMissed** | Heartbeat file age > 30min (3x poll interval) | P1 | PagerDuty + Feishu | 10min |
| **GitLabAPIAuthFailure** | HTTP 401/403 from GitLab API | P1 | PagerDuty + Feishu | 30min |
| **GitLabAPIRateLimited** | HTTP 429, backoff triggered | P2 | Feishu Ops | 15min |
| **GitLabAPIFailure** | HTTP 5xx for multiple consecutive polls | P2 | Feishu Ops | 15min |
| **ScriptCrash** | `check-issues.sh` exits non-zero | P2 | Feishu Ops | 15min |
| **StateFileCorrupt** | `last_iid` is not a valid integer | P2 | Feishu Ops | 30min |
| **P0DeliveryFailed** | P0 notification not confirmed delivered within TTL | P1 | PagerDuty + Feishu | 5min |
| **P1DeliveryFailed** | P1 notification delivery failure | P2 | Feishu Ops | 15min |
| **PriorityEngineDown** | All issues defaulting to P3 (engine producing no signals) | P2 | Feishu Ops | 30min |
| **TooManyP0** | > 3 P0 issues in 1h window | P2 | Feishu Ops | 30min |

### 4.3 Heartbeat Mechanism

```bash
# At end of successful check-issues.sh run:
date +%s > /data/issue-automation/heartbeat
```

A separate lightweight monitor (`heartbeat-check.sh`) runs every 5 minutes via cc-connect cron:

```bash
#!/usr/bin/env bash
# heartbeat-check.sh — P1 alert if issue automation hasn't polled recently
set -euo pipefail

HEARTBEAT_FILE="/data/issue-automation/heartbeat"
MAX_AGE_SECONDS=1800  # 30 minutes = 3x poll interval

if [ ! -f "$HEARTBEAT_FILE" ]; then
  cc-connect send --chat-id "$OPS_CHAT_ID" \
    --title "[P1] Issue Automation Heartbeat Missing" \
    --text "Heartbeat file not found at $HEARTBEAT_FILE. Pipeline may not have started."
  exit 1
fi

last_beat=$(cat "$HEARTBEAT_FILE")
now=$(date +%s)
age=$((now - last_beat))

if [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
  cc-connect send --chat-id "$OPS_CHAT_ID" \
    --title "[P1] Issue Automation Heartbeat Stale" \
    --text "Last heartbeat was ${age}s ago (max ${MAX_AGE_SECONDS}s). Poll cycle may be stuck or crashed."
  exit 1
fi
```

### 4.4 Alert Payload Format

All alerts use a consistent feishu message card format:

```json
{
  "title": "[P1] Issue Automation — Cron Heartbeat Missed",
  "body": "check-issues.sh has not completed successfully in the last 35 minutes.\n\nLast heartbeat: 2026-05-23T14:25:00Z\nMax interval: 30 minutes\nTotal missed cycles: 3\n\nCheck: docker logs cc-connect | grep check-issues\nFix: Restart cc-connect container if stuck",
  "severity": "P1",
  "source": "issue-automation",
  "alert_rule": "CronHeartbeatMissed",
  "timestamp": "2026-05-23T15:00:00Z"
}
```

---

## 5. Notification Format by Priority

### 5.1 P0/P1 — Immediate Notification (Feishu Card)

```
┌─────────────────────────────────────────────────────┐
│ 🔴 [P0] Production Down — kyb-create broken        │
│                                                     │
│ Issue #142 by @aoyama  ·  opened 2min ago           │
│                                                     │
│ All kyb create commands fail with "network          │
│ timeout" on production hosts.                       │
│                                                     │
│ Labels: severity::critical, area::production         │
│ Priority signals: label+content+team_member           │
│                                                     │
│ 🔗 https://git.leyantech.com/kyb/infra/core/issues/142│
└─────────────────────────────────────────────────────┘
```

### 5.2 P2 — Batched Notification (every 30 min)

A summary card listing all new P2 issues since last batch:

```
┌─────────────────────────────────────────────────────┐
│ 🟡 [P2] New Issues — Batch 14:30                    │
│                                                     │
│ • #144 kyb exec slow on large repos                 │
│   by @user  ·  area::performance                    │
│ • #145 Add timeout config for kyb create            │
│   by @user  ·  type::feature                        │
│                                                     │
│ 2 new P2 issues in the last 30 minutes              │
│ 🔗 View all open issues                             │
└─────────────────────────────────────────────────────┘
```

### 5.3 P3/P4 — Daily Summary (scheduled at 09:00)

```
┌─────────────────────────────────────────────────────┐
│ ⚪ Issue Daily Summary — 2026-05-23                  │
│                                                     │
│ New issues today: 8                                  │
│   P0: 0  P1: 1  P2: 3  P3: 3  P4: 1                │
│                                                     │
│ Unresolved aging (flagged):                          │
│ • #140 Feature request — 4 days old → P3→P2 today   │
│ • #138 Nice to have — 7 days old → P4→P3 today      │
│                                                     │
│ Automation health: ✅ All systems normal             │
│ Poll cycles today: 138  ·  Success rate: 100%       │
└─────────────────────────────────────────────────────┘
```

---

## 6. Script Changes from v1

### 6.1 `check-issues.sh` — v2

```bash
#!/usr/bin/env bash
# check-issues.sh v2 — GitLab issue poller with auto-priority
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin"

STATE_DIR="/data/issue-automation"
LAST_IID_FILE="${STATE_DIR}/last_iid"
HEARTBEAT_FILE="${STATE_DIR}/heartbeat"
PRIORITIES_FILE="${STATE_DIR}/priorities.json"
HISTORY_FILE="${STATE_DIR}/priority_history.jsonl"
STATE_TMP="${STATE_DIR}/.last_iid.tmp"

PROJECT_ID="kyb/infra/core"  # configurable per project
GITLAB_TOKEN_FILE="/run/secrets/gitlab_token"
OPS_CHAT_ID="oc_xxx_ops_chat"  # from cc-connect config

# Options
NOTIFY_P0_P1=true
NOTIFY_P2=true
BATCH_P2_INTERVAL=1800  # 30 minutes
DRY_RUN=false

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Read state
last_iid=$(cat "$LAST_IID_FILE" 2>/dev/null || echo "0")
case "$last_iid" in
  ''|*[!0-9]*) last_iid=0 ;;  # non-numeric → reset
esac

# Validate token file
if [ ! -r "$GITLAB_TOKEN_FILE" ]; then
  echo "ERROR: GitLab token file not readable: $GITLAB_TOKEN_FILE" >&2
  cc-connect send --chat-id "$OPS_CHAT_ID" \
    --title "[P2] Issue Automation — Token File Missing" \
    --text "Cannot read $GITLAB_TOKEN_FILE. Check Docker secrets mount."
  exit 1
fi

token=$(cat "$GITLAB_TOKEN_FILE")

# Fetch issues (with timeout and retry)
response=$(curl -fsSL \
  --connect-timeout 10 \
  --max-time 30 \
  --retry 2 \
  --retry-delay 5 \
  -H "PRIVATE-TOKEN: ${token}" \
  "https://git.leyantech.com/api/v4/projects/${PROJECT_ID}/issues?updated_after=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')&scope=all&per_page=100&sort=created_at&order=asc" 2>/dev/null) || {
  echo "ERROR: GitLab API request failed" >&2
  cc-connect send --chat-id "$OPS_CHAT_ID" \
    --title "[P2] Issue Automation — GitLab API Unreachable" \
    --text "check-issues.sh failed to reach GitLab API. Will retry in 10 minutes."
  exit 1
}

# Validate JSON response
echo "$response" | jq -e '.' > /dev/null 2>&1 || {
  echo "ERROR: Invalid JSON from GitLab API" >&2
  exit 1
}

# Check for API error in response
http_status=$(echo "$response" | jq -r 'if type=="object" and .error then .error else "ok" end')
if [ "$http_status" != "ok" ]; then
  echo "ERROR: GitLab API returned error: $(echo "$response" | jq -r '.error // .message')" >&2
  exit 1
fi

# Process new issues
new_iid=$last_iid
new_issues=$(echo "$response" | jq -c ".[] | select(.iid > $last_iid)")

echo "$new_issues" | while IFS= read -r issue; do
  [ -z "$issue" ] && continue

  iid=$(echo "$issue" | jq -r '.iid')
  title=$(echo "$issue" | jq -r '.title')
  author=$(echo "$issue" | jq -r '.author.username')
  labels=$(echo "$issue" | jq -r '.labels | join(",")')
  description=$(echo "$issue" | jq -r '.description // ""')
  created_at=$(echo "$issue" | jq -r '.created_at')
  url=$(echo "$issue" | jq -r '.web_url')

  # → Compute priority (see Section 3)
  priority_result=$(python3 /scripts/priority-engine.py \
    --title "$title" \
    --description "$description" \
    --labels "$labels" \
    --author "$author" \
    --project "$PROJECT_ID" \
    --created-at "$created_at" \
    --last-iid "$last_iid" \
    --format json 2>/dev/null)

  priority=$(echo "$priority_result" | jq -r '.priority // "P3"')
  signals=$(echo "$priority_result" | jq -r '.signals | join(",")')
  confidence=$(echo "$priority_result" | jq -r '.confidence // 0.5')

  # → Notify
  case "$priority" in
    P0|P1)
      cc-connect send --chat-id "$OPS_CHAT_ID" \
        --title "[$priority] Issue #${iid}: ${title:0:80}" \
        --text "By @${author} · opened ${created_at}\n\nLabels: ${labels:-none}\nPriority signals: ${signals}\nConfidence: ${confidence}\n\n${url}"
      # P0/P1 goes through delivery tracker for delivery confirmation
      ;;
    P2)
      if $NOTIFY_P2; then
        echo "$issue" >> "${STATE_DIR}/p2_batch.jsonl"
      fi
      ;;
    P3|P4)
      echo "$issue" >> "${STATE_DIR}/daily_queue.jsonl"
      ;;
  esac

  # → Log priority decision
  echo "{\"iid\":$iid,\"priority\":\"$priority\",\"signals\":\"$signals\",\"confidence\":$confidence,\"computed_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"title\":$(echo "$title" | jq -Rsa .)}" \
    >> "$HISTORY_FILE"

  if [ "$iid" -gt "$new_iid" ]; then
    new_iid=$iid
  fi
done

# → Flush P2 batch if interval elapsed
p2_batch_lastrun="${STATE_DIR}/.p2_batch_lastrun"
p2_batch_now=$(date +%s)
p2_batch_prev=$(cat "$p2_batch_lastrun" 2>/dev/null || echo "0")
if [ -s "${STATE_DIR}/p2_batch.jsonl" ] && [ $((p2_batch_now - p2_batch_prev)) -ge $BATCH_P2_INTERVAL ]; then
  p2_count=$(wc -l < "${STATE_DIR}/p2_batch.jsonl")
  p2_summary=$(head -5 "${STATE_DIR}/p2_batch.jsonl" | jq -r '. | "#\(.iid) \(.title) by @\(.author.username)"' | head -3)
  cc-connect send --chat-id "$OPS_CHAT_ID" \
    --title "[P2] New Issues — Batch $(date +%H:%M)" \
    --text "${p2_count} new P2 issues\n\n${p2_summary}"
  : > "${STATE_DIR}/p2_batch.jsonl"
  echo "$p2_batch_now" > "$p2_batch_lastrun"
fi

# → Atomic state update
echo "$new_iid" > "$STATE_TMP"
mv "$STATE_TMP" "$LAST_IID_FILE"

# → Update priorities.json (recent only, keep last 100)
echo "$priority_result" > /dev/null  # priority already tracked in history_file

# → Heartbeat
date +%s > "$HEARTBEAT_FILE"

echo "OK: processed issues up to IID $new_iid"
```

### 6.2 `priority-engine.py` — NEW Standalone Script

```python
#!/usr/bin/env python3
"""
priority-engine.py — Compute issue priority from multiple signals.

Usage:
  python3 priority-engine.py \
    --title "..." \
    --description "..." \
    --labels "severity::high,type::bug" \
    --author "aoyama" \
    --project "kyb/infra/core" \
    --created-at "2026-05-23T10:00:00Z" \
    --format json
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone

# ── Priority Levels ──────────────────────────────────
P0, P1, P2, P3, P4 = 0, 1, 2, 3, 4
LEVEL_NAMES = {0: "P0", 1: "P1", 2: "P2", 3: "P3", 4: "P4"}
DEFAULT_PRIORITY = P3

# ── Label → Priority Map ─────────────────────────────
LABEL_PRIORITY = {
    # Severity
    "severity::critical": P0,
    "severity::high": P1,
    "severity::medium": P2,
    "severity::low": P3,
    # Type
    "type::security": P0,
    "type::bug": P1,
    "type::performance": P2,
    "type::feature": P3,
    "type::enhancement": P3,
    "type::documentation": P3,
    "type::question": P4,
    # Area
    "area::production": P1,
    "area::deployment": P2,
    "area::ci": P2,
    "area::testing": P3,
    # Explicit priority labels (override everything)
    "priority::immediate": P0,
    "priority::urgent": P1,
    "priority::high": P1,
    "priority::normal": P2,
    "priority::low": P3,
}

# ── Content Keywords ─────────────────────────────────
FORCE_P0_KEYWORDS = [
    r"production down",
    r"完全不可用",
    r"数据丢失",
    r"data loss",
    r"security breach",
    r"outage",
    r"crash.*all",
    r"all.*crash",
    r"data breach",
    r"security incident",
    r"P0",
]

BOOST_P1_KEYWORDS = [
    r"crash",
    r"崩溃",
    r"500 error",
    r"cannot deploy",
    r"blocked",
    r"blocking",
    r"urgent",
    r"紧急",
    r"立刻",
    r"broken",
    r"regression",
    r"down",
    r"宕机",
]

BOOST_P2_KEYWORDS = [
    r"slow",
    r"延迟",
    r"timeout",
    r"error",
    r"failed",
    r"失败",
    r"warning",
    r"提醒",
    r"degraded",
]

# ── Author Map ────────────────────────────────────────
TEAM_MEMBERS = [
    "aoyama",
]

BOT_ACCOUNTS = [
    "gitlab-bot",
    "renovate-bot",
    "dependabot",
]

# ── Project Base Priority ─────────────────────────────
PROJECT_PRIORITY = {
    "kyb/infra/core": P1,
    "kyb/infra/tooling": P2,
    "kyb/infra/observability": P1,
    "kyb/app": P2,
    "kyb/docs": P3,
    "kyb/experimental": P3,
}


def compute_priority(
    title: str,
    description: str,
    labels: str,
    author: str,
    project: str,
    created_at: str,
) -> dict:
    signals = []
    content = f"{title}\n{description}"
    label_list = [l.strip() for l in labels.split(",") if l.strip()]
    confidence = 0.5

    # Step 1: Labels
    label_priority = DEFAULT_PRIORITY
    for label in label_list:
        if label in LABEL_PRIORITY:
            lp = LABEL_PRIORITY[label]
            if lp < label_priority:
                label_priority = lp
                signals.append(f"label:{label}")

    # Step 2: Content analysis
    content_boost = 0

    # Force P0 keywords override everything
    for kw in FORCE_P0_KEYWORDS:
        if re.search(kw, content, re.IGNORECASE):
            return {
                "priority": "P0",
                "signals": [f"force_p0:{kw}"],
                "confidence": 0.95,
            }

    for kw in BOOST_P1_KEYWORDS:
        if re.search(kw, content, re.IGNORECASE):
            content_boost = max(content_boost, 1)
            signals.append(f"content_boost_p1:{kw}")

    for kw in BOOST_P2_KEYWORDS:
        if re.search(kw, content, re.IGNORECASE):
            content_boost = max(content_boost, 2)
            signals.append(f"content_boost_p2:{kw}")

    # Step 3: Author
    author_boost = 0
    if author in BOT_ACCOUNTS:
        author_boost = 0  # bots don't boost
    elif author in TEAM_MEMBERS:
        author_boost = -1  # team member → higher priority
        signals.append(f"team_author:{author}")

    # Step 4: Project base
    project_base = DEFAULT_PRIORITY
    for proj_key, proj_pri in sorted(PROJECT_PRIORITY.items(), key=lambda x: -len(x[0])):
        if project.startswith(proj_key) or proj_key in project:
            project_base = min(project_base, proj_pri)
            signals.append(f"project:{proj_key}")

    # Step 5: Combine
    priority = min(label_priority, project_base)  # higher priority wins
    priority = max(P0, priority - content_boost)   # boost (never exceed P0)
    priority = max(P0, priority + author_boost)    # team boost (negative = higher)

    # Step 6: Time decay
    try:
        created_dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        age_hours = (now - created_dt).total_seconds() / 3600

        # Only apply if not already triaged
        if "priority::triaged" not in label_list:
            if priority == P4 and age_hours > 168:  # 7 days
                priority = P3
                signals.append("time_decay:P4→P3:7d")
            elif priority == P3 and age_hours > 72:  # 3 days
                priority = P2
                signals.append("time_decay:P3→P2:3d")
            elif priority == P2 and age_hours > 24:  # 1 day, SLA is 4h
                priority = P1
                signals.append("time_decay:P2→P1:1d")
    except (ValueError, TypeError):
        pass  # skip time decay on parse error

    # Confidence: higher when more signals agree
    signal_count = len(signals)
    if label_priority != DEFAULT_PRIORITY and content_boost > 0:
        confidence = 0.9
    elif label_priority != DEFAULT_PRIORITY:
        confidence = 0.8
    elif content_boost > 0:
        confidence = 0.7
    elif signal_count > 1:
        confidence = 0.6
    else:
        confidence = 0.4  # mostly project default

    return {
        "priority": LEVEL_NAMES[priority],
        "signals": signals,
        "confidence": confidence,
    }


def main():
    parser = argparse.ArgumentParser(description="Compute GitLab issue priority")
    parser.add_argument("--title", required=True)
    parser.add_argument("--description", default="")
    parser.add_argument("--labels", default="")
    parser.add_argument("--author", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--created-at", required=True)
    parser.add_argument("--format", choices=["json", "text"], default="json")
    args = parser.parse_args()

    result = compute_priority(
        title=args.title,
        description=args.description,
        labels=args.labels,
        author=args.author,
        project=args.project,
        created_at=args.created_at,
    )

    if args.format == "json":
        print(json.dumps(result))
    else:
        print(f"{result['priority']}\t{','.join(result['signals'])}\t{result['confidence']}")


if __name__ == "__main__":
    main()
```

### 6.3 Heartbeat Check Script — NEW

```bash
#!/usr/bin/env bash
# heartbeat-check.sh v1 — P1 alert if issue automation is stalled
set -euo pipefail

HEARTBEAT_FILE="/data/issue-automation/heartbeat"
MAX_AGE=1800  # 30 minutes
OPS_CHAT_ID="${OPS_CHAT_ID:-oc_xxx_ops}"

if [ ! -f "$HEARTBEAT_FILE" ]; then
  cc-connect send --chat-id "$OPS_CHAT_ID" \
    --title "[P1] Issue Automation: Heartbeat Missing" \
    --text "Heartbeat file not found at ${HEARTBEAT_FILE}.\nPipeline may not have started.\nCheck: docker logs cc-connect | grep check-issues"
  exit 1
fi

last_beat=$(cat "$HEARTBEAT_FILE")
now=$(date +%s)
age=$((now - last_beat))

if [ "$age" -gt "$MAX_AGE" ]; then
  missed_cycles=$((age / 600))
  last_beat_human=$(date -d @"$last_beat" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")
  cc-connect send --chat-id "$OPS_CHAT_ID" \
    --title "[P1] Issue Automation: Heartbeat Stale" \
    --text "Last heartbeat: ${last_beat_human} (${age}s ago)\nMax interval: ${MAX_AGE}s\nMissed cycles: ~${missed_cycles}\n\nCheck: docker logs cc-connect | grep check-issues\nFix: Restart cc-connect or check cron config"
  exit 1
fi
```

---

## 7. Cron Configuration

### 7.1 cc-connect Cron Entries

```yaml
# cc-connect cron configuration
cron:
  jobs:
    - name: check-issues
      schedule: "*/10 * * * *"
      command: "timeout 60 sh /scripts/check-issues.sh"
      description: "GitLab Issue Tracker — poll new issues"
      on_failure: "log"  # error goes to cc-connect log; heartbeat alert covers missed runs

    - name: heartbeat-check
      schedule: "*/5 * * * *"
      command: "timeout 15 sh /scripts/heartbeat-check.sh"
      description: "Check issue automation heartbeat"
      on_failure: "alert"  # heartbeat-check exits 1 when stale → cc-connect can escalate

    - name: daily-summary
      schedule: "0 1 * * *"  # 09:00 CST (01:00 UTC)
      command: "sh /scripts/daily-summary.sh"
      description: "Daily issue summary to feishu"
      on_failure: "log"
```

### 7.2 Script Execution Guard

To prevent overlapping cron executions (if a long-running poll is still running when the next tick fires):

```bash
# At the top of check-issues.sh:
LOCK_FILE="${STATE_DIR}/.check-issues.lock"

if ! mkdir "$LOCK_FILE" 2>/dev/null; then
  echo "Previous run still in progress, skipping"
  exit 0
fi
trap 'rm -rf "$LOCK_FILE"' EXIT
```

This uses `mkdir` as an atomic lock (mkdir is atomic on Linux; no race condition).

---

## 8. Integration with Existing Infra

### 8.1 Feishu Delivery Tracking

P0/P1 issue notifications use the delivery tracking infrastructure from `feishu-delivery.md`:

```
check-issues.sh → cc-connect send → Delivery Tracker → Track delivery state
                                                      ├── SENT → DELIVERED → normal
                                                      └── SENT → DROPPED → alert ops (P1)
```

The delivery tracker wrapper:
```bash
# Instead of:
cc-connect send --chat-id "$OPS_CHAT_ID" --title "..."

# Use delivery-tracked wrapper:
delivery-tracker send --category urgent --tag "issue-auto:P0" \
  -- cc-connect send --chat-id "$OPS_CHAT_ID" --title "..."
```

The `tag` field allows the delivery tracker to correlate failed deliveries back to issue automation, triggering `P0DeliveryFailed` alert.

### 8.2 ClickHouse Events

All poll cycles are logged to ClickHouse for historical analysis:

```sql
CREATE TABLE IF NOT EXISTS infra.issue_automation_events (
  timestamp     DateTime64(3),
  poll_iid      UInt32,            -- last_iid after this poll
  issues_found  UInt8,             -- new issues detected
  p0_count      UInt8,
  p1_count      UInt8,
  p2_count      UInt8,
  p3_p4_count   UInt8,
  duration_ms   UInt32,            -- script execution time
  success       UInt8,             -- 1 = success, 0 = failure
  error_msg     String DEFAULT '',
  priority_json String DEFAULT '', -- snapshot of priority decisions
  _ingested_at  DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY (toDate(timestamp))
TTL toDate(timestamp) + INTERVAL 90 DAY;
```

The script appends to a local JSON log, which Vector or a cron-based ingester pushes to ClickHouse:

```bash
# In check-issues.sh (appended after heartbeat update):
echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"poll_iid\":$new_iid,\"issues_found\":$issues_found,\"p0_count\":$p0_count,\"p1_count\":$p1_count,\"p2_count\":$p2_count,\"p3_p4_count\":$p3_p4_count,\"duration_ms\":$duration_ms,\"success\":1}" \
  >> "${STATE_DIR}/poll_log.jsonl"
```

### 8.3 Grafana Dashboard Panels

| Panel | Query | Purpose |
|-------|-------|---------|
| Poll Success Rate | `sum(success) / count(*) as rate over 1h` | Automation health |
| Heartbeat Age | `current_time - max(heartbeat_timestamp)` | Stale pipeline detection |
| Issue Priority Distribution | `count by(priority)` | Triage workload overview |
| P0/P1 Issue Rate | `count by(priority) where priority in (P0, P1)` | Urgent issue velocity |
| Notification Delivery Rate | `delivered/sent by priority` | Feishu delivery health |
| Priority Engine Signal Breakdown | `count by(signal_type)` | Which signals drive decisions |
| Aging Issues | `count where age_hours > SLA threshold` | Un-triaged issue backlog |

### 8.4 Feishu Card for Daily Summary

The daily summary card (scheduled via cc-connect cron at 09:00 CST):

```
┌──────────────────────────────────────────────────────────┐
│  📋 Issue Automation Daily Report — 2026-05-23           │
│                                                          │
│  New issues: 8 (P0:0 P1:1 P2:3 P3:3 P4:1)              │
│  ─────────────────────────────────────────────           │
│                                                          │
│  🟠 P1: #145 kyb exec timeout regression                 │
│      by @aoyama  ·  area::production                     │
│                                                          │
│  🟡 P2: #146 Add logging to kyb create                   │
│      by @user  ·  type::feature                          │
│  🟡 P2: #147 Slow image pull on ARM                      │
│      by @user  ·  area::deployment                       │
│  🟡 P2: #148 Migrate to docker compose v2                │
│      by @user  ·  type::enhancement                      │
│                                                          │
│  Aging (auto-escalated):                                 │
│  • #140 Feature request → P3→P2 (3d, not triaged)       │
│                                                          │
│  Automation Health: ✅ All systems normal                │
│  Poll cycles today: 138/138 (100%)                       │
│  Notification delivery: 97/98 (98.9%)                    │
│                                                          │
│  🔗 View all issues                                      │
└──────────────────────────────────────────────────────────┘
```

---

## 9. Failure Modes and Mitigations

| Failure | Detection | Impact | Mitigation |
|---------|-----------|--------|------------|
| `check-issues.sh` hangs | Script-level timeout (60s) | One missed poll cycle | Heartbeat check fires P1 alert after 30min |
| cc-connect cron subsystem broken | All cron jobs stop | All automation stops | Docker health check on cc-connect container; heartbeat alert |
| GitLab API outage (5xx) | curl exit code non-zero | Delay in issue detection | Script exits gracefully, no state change, no duplicate notification risk |
| GitLab API auth failure (401) | HTTP 401 response | No issue detection | P2 alert on first occurrence, stop polling until token renewed |
| GitLab API rate limit (429) | HTTP 429 response | Temporary polling pause | Backoff (curl --retry), P2 alert if persistent |
| State file corruption | `last_iid` non-numeric | May re-notify existing issues | Reset to 0, P2 alert, manual recovery |
| State file write failure | `mv` fails after tmp write | `last_iid` stays old, re-notifies | P2 alert, script continues with old IID |
| Priority engine fails | Python script error | All issues default to P3 | P2 alert ("PriorityEngineDown"), all notifications sent as P3 |
| Notification delivery fails | Delivery tracker → DROPPED | P0/P1 issue not seen | P1 alert, retry once, manual escalation |
| Duplicate cron execution | Lock file contention | Overlapping API calls | Lock file guard skips overlapping execution |
| Container restart mid-poll | State file partially written | `last_iid` may be old | Atomic tmp+mv ensures state is never partially written |
| Heartbeat check fails to send alert | `cc-connect send` itself fails | Silent alert loss | The heartbeat check also increments a "last alert attempt" file; if that also goes stale, only PagerDuty-level monitoring catches it (Docker container health) |

### 9.1 Failure Mode: What Happens When Everything Breaks

If cc-connect goes down entirely:

```
cc-connect down
├── Cron jobs stop → no polling, no heartbeat updates
├── Heartbeat file goes stale (age > 30min)
├── Heartbeat check would fire... but it's also a cron job
├── No feishu alerts can be sent (cc-connect is the feishu transport)
└── Detection: Docker container restart policy (unless-stopped)
    → Eventually recovers when Docker restarts the container
    → On restart: state file intact, poll resumes from last_iid
    → No duplicate notifications (state file survives)
    → ~2-6 minutes of missed polls during restart
```

**Docker-level monitoring** (the last line of defense):

```yaml
# docker-compose healthcheck for cc-connect itself
healthcheck:
  test: ["CMD", "test", "-f", "/data/issue-automation/heartbeat", "-a", "$$(($$(date +%s) - $$(cat /data/issue-automation/heartbeat)))", "-lt", "3600"]
  interval: 5m
  timeout: 10s
  retries: 3
  start_period: 30s
```

This Docker health check fails if the heartbeat file is older than 1 hour. Docker marks the container unhealthy, and external monitoring (Portainer, Watchtower, or a host-level cron) can alert.

---

## 10. Implementation Plan

### Phase 1: Priority Engine (Day 1, < 2h)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 1.1 | Write `priority-engine.py` with label + content + author + project signals | — |
| 1.2 | Unit tests for each signal type (especially edge cases: no labels, bot author, Chinese keywords) | 1.1 |
| 1.3 | Integration test: pipe sample issues through engine, verify priority output | 1.2 |
| 1.4 | Deploy `priority-engine.py` to cc-connect container (bind mount or Dockerfile layer) | 1.1 |

**Verification:** Run `priority-engine.py` with sample issue data, confirm P0-P4 output with correct signals.

### Phase 2: `check-issues.sh` v2 (Day 1, < 3h)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 2.1 | Update `check-issues.sh`: add priority engine call, notification routing, heartbeat write | 1.1 |
| 2.2 | Add atomic state writes, lock file guard, timeout wrapper | E1/E3 review findings |
| 2.3 | Add P2 batching and daily summary queue logic | 2.1 |
| 2.4 | Write `heartbeat-check.sh` | — |
| 2.5 | Write `daily-summary.sh` | 2.3 |
| 2.6 | Deploy all scripts to cc-connect container | 2.1-2.5 |

**Verification:** Create a test issue with `severity::critical` label, confirm P0 notification arrives within 10 minutes with correct format. Create a feature request issue, confirm no immediate notification (goes to daily queue).

### Phase 3: Feishu Alerts Integration (Day 2, < 2h)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 3.1 | Create feishu alert message card templates for each alert rule | — |
| 3.2 | Wire `heartbeat-check.sh` to `cc-connect send` with P1 alert format | 2.4 |
| 3.3 | Wire script error handlers to `cc-connect send` for P2 alerts | 2.1 |
| 3.4 | Integrate P0/P1 notification delivery with `delivery-tracker` (from `feishu-delivery.md`) | `feishu-delivery.md` Phase 1-2 |

**Verification:** Kill `check-issues.sh` mid-execution (simulate crash), wait 30 minutes, confirm P1 heartbeat alert fires. Verify delivery tracker records P0 notification state transitions.

### Phase 4: Observability (Day 2-3, < 2h)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 4.1 | Create `infra.issue_automation_events` table in ClickHouse | — |
| 4.2 | Add poll logging JSONL output to `check-issues.sh` v2 | 2.1 |
| 4.3 | Ingest poll logs into ClickHouse (via Vector or cron-based script) | 4.1, 4.2 |
| 4.4 | Build Grafana dashboard: poll success rate, priority distribution, aging issues | 4.3 |
| 4.5 | Add Grafana alert: "No poll events in 30min" as P2 | 4.4 |

**Verification:** After 3+ poll cycles, query ClickHouse and see poll events. Grafana dashboard shows success rate = 100%.

### Phase 5: Daily Summary (Day 3, < 1h)

| Step | Deliverable | Depends On |
|------|-------------|------------|
| 5.1 | Write `daily-summary.sh`: aggregate daily queue, fetch priority distribution from CK, format feishu card | Phase 3 |
| 5.2 | Add cron entry for 01:00 UTC daily | 5.1 |
| 5.3 | Test: run script manually, verify feishu card format | 5.1 |

---

## 11. Effort Estimate

| Phase | Task | Time |
|-------|------|------|
| 1 | Priority engine (Python script + tests) | 2h |
| 2 | check-issues.sh v2 + helper scripts | 3h |
| 3 | Feishu alerts + delivery tracking integration | 2h |
| 4 | Observability (CK table + Grafana) | 2h |
| 5 | Daily summary card | 1h |
| **Total** | **Implementation** | **10h** |
| | **Total with review + testing + deploy** | **~14h (2 days)** |

---

## 12. Comparison: v1 vs v2

| Capability | v1 | v2 |
|------------|----|----|
| Poll GitLab issues | ✅ cc-connect cron, 10min | ✅ Same (inherited) |
| Notify feishu group | ✅ cc-connect send | ✅ Same (inherited) |
| State persistence | ✅ last_iid file | ✅ Atomic tmp+mv writes |
| Token security | ❌ In script (E2 finding) | ✅ `/run/secrets/gitlab_token` |
| Script hardening | ❌ No timeout, no `-f` | ✅ `timeout 60`, `-fsSL`, lock file |
| **Priority classification** | ❌ None | ✅ 5-tier (P0-P4) from labels+content+author+project |
| **Feishu alerts on failure** | ❌ Silent failures | ✅ P1 heartbeat + P2 API error alerts |
| **Notification routing by priority** | ❌ All issues notified same way | ✅ P0/P1 immediate, P2 batched, P3/P4 daily |
| **Delivery confirmation** | ❌ Fire-and-forget | ✅ P0/P1 tracked via delivery tracker |
| **Priority time decay** | ❌ N/A | ✅ Untriaged issues escalate over time |
| **Observability** | ❌ None | ✅ ClickHouse events + Grafana dashboard |
| **Stale detection** | ❌ No heartbeat | ✅ Heartbeat file + Docker healthcheck |
| **Overlap protection** | ❌ None | ✅ Lock file guard |
| **Chinese language support** | ❌ N/A | ✅ Chinese keyword matching + priority signals |

---

## 13. References

- v1 design: `docs/infra/designs/issue-automation.md`
- Review E1 (cron reliability): `docs/infra/reviews/review-issue-automation-E1.md`
- Review E2 (GitLab API): `docs/infra/reviews/review-issue-automation-E2.md`
- Review E3 (curl script): `docs/infra/reviews/review-issue-automation-E3.md`
- Feishu delivery monitoring: `docs/infra/reviews/feishu-delivery.md`
- Mention response tracking: `docs/infra/reviews/mention-response.md`
- Feishu webhook intercept: `docs/infra/reviews/feishu-webhook-intercept.md`
- cc-connect hooks to CK: `docs/infra/reviews/cc-hooks-direct-ck.md`
- Patrol guide: `docs/infra/5min-patrol-guide.md`
- Multi-cluster architecture: `docs/infra/multi-cluster-boss-architecture.md`

---

/人◕ ‿‿ ◕人＼
