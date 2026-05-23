---
decision: 稍后做
---

# On-Call Integration for Infra Alerts

**Author:** Boss
**Status:** Draft
**Date:** 2026-05-23
**File:** `docs/infra/reviews/oncall.md`

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Notification Routing: Feishu Integration](#2-notification-routing-feishu-integration)
3. [Escalation Policy](#3-escalation-policy)
4. [Alert Acknowledgement Tracking](#4-alert-acknowledgement-tracking)
5. [Handover Notes](#5-handover-notes)
6. [Schedule Management](#6-schedule-management)
7. [Grafana Integration](#7-grafana-integration)
8. [Implementation Phases](#8-implementation-phases)
9. [Runbook](#9-runbook)

---

## 1. Problem Statement

Infra alerts currently fire into Feishu groups without a defined on-call rotation. The result is a weakest-link notification model: everyone sees everything, nobody is responsible, and alerts fall through the cracks.

### Current State

| Gap | Impact |
|-----|--------|
| No defined on-call rotation | Alerts hit @all or @oncall with no clear ownership |
| No escalation path | If the first responder misses an alert, there is no automatic escalation |
| No acknowledgement tracking | Cannot distinguish "seen but working" from "never seen" |
| No handover mechanism | Shift changes are silent; context is lost |
| No schedule visibility | The infra team doesn't know who is on call at any given time |
| Feishu group @oncall has no roster | Tag resolves to nobody because no one set up the Feishu on-call group |

### Goal

Design an on-call integration that:
1. Routes alerts to the right person via Feishu, with clear ownership
2. Escalates automatically when the primary is unreachable
3. Tracks acknowledgements and measures MTTA per on-call shift
4. Supports structured handovers between shifts
5. Works with the existing infrastructure (no new SaaS, no PagerDuty)

### Scope

| Included | Not included |
|----------|-------------|
| Feishu notification routing (P0/P1/P2 tiers) | Phone call / SMS alerting |
| Multi-level escalation policy | Geographic follow-the-sun rotation |
| Acknowledgement tracking in ClickHouse | Vacation / PTO scheduling |
| Handover notes format and workflow | Integration with external calendaring |
| On-call schedule management via Feishu | Capacity planning / staffing model |
| Grafana on-call integration (Grafana -> Feishu routing) | Out-of-hours compensation tracking |

---

## 2. Notification Routing: Feishu Integration

### 2.1 Architecture Overview

```
Alert Source ──> AlertManager ──> Webhook ──> Feishu Bot ──> Feishu Group
                                                     │
                                                     ├── P0: @all + urgent notification card
                                                     ├── P1: @on-call + notification card
                                                     └── P2: silent notification card
```

**Components:**

1. **AlertManager** -- existing alert rule evaluation and dedup
2. **Feishu Webhook Bridge** -- the `feishu-bridge` service (already deployed) converts AlertManager webhooks to Feishu message cards
3. **Feishu Bot** -- a custom bot in each alert group, posts cards with action buttons
4. **On-Call Roster** -- a ClickHouse-backed lookup table mapping `date + shift` to `on-call user Feishu ID`

### 2.2 Alert Severity Tiers

| Severity | Feishu Notification Method | Target | Response SLO |
|----------|---------------------------|--------|-------------|
| **P0** | @all + urgent card (red banner, TTS via `kyb notify`) | All available engineers | < 5 min |
| **P1** | @on-call + card (orange banner) | On-call engineer | < 15 min |
| **P2** | Card only (yellow banner), no @mention | On-call engineer (non-urgent) | < 1 hour (business hours) |
| **P3** | Daily digest card (blue banner) at 10:00 | @all (informational) | Next working day |
| **Info** | No card, logged to ClickHouse only | Nobody | N/A |

### 2.3 Feishu Message Card Templates

**P0 Card (urgent):**

```json
{
  "config": { "wide_screen_mode": true },
  "header": {
    "title": { "tag": "plain_text", "content": "P0: cc-connect is DOWN" },
    "template": "red"
  },
  "elements": [
    { "tag": "div", "text": { "tag": "lark_md", "content": "**Service:** cc-connect\n**Cluster:** mac-orbstack\n**Since:** 2026-05-23 14:22:30 UTC\n**Duration:** 3m 12s\n**Runbook:** [docs/infra/runbooks/cc-connect-down.md](...)" } },
    { "tag": "hr" },
    { "tag": "div", "text": { "tag": "lark_md", "content": "@all Critical alert requires immediate attention." } },
    { "tag": "action", "actions": [
      { "tag": "button", "text": { "tag": "plain_text", "content": "Acknowledge" }, "type": "primary", "value": { "action": "ack", "alert_id": "abc123" } },
      { "tag": "button", "text": { "tag": "plain_text", "content": "View Runbook" }, "type": "default", "value": { "action": "runbook", "alert_id": "abc123" } },
      { "tag": "button", "text": { "tag": "plain_text", "content": "Silence 30m" }, "type": "danger", "value": { "action": "silence", "alert_id": "abc123", "duration": "30m" } }
    ]}
  ]
}
```

**P1 Card (on-call):**

```json
{
  "config": { "wide_screen_mode": true },
  "header": {
    "title": { "tag": "plain_text", "content": "P1: Disk usage at 87% on sim" },
    "template": "orange"
  },
  "elements": [
    { "tag": "div", "text": { "tag": "lark_md", "content": "**Service:** sim host disk\n**Current:** 87%\n**Threshold:** 80%\n**Host:** 47.100.71.220\n**Runbook:** [docs/infra/runbooks/disk-full.md](...)" } },
    { "tag": "hr" },
    { "tag": "div", "text": { "tag": "lark_md", "content": "@on-call Please acknowledge within 15 minutes." } },
    { "tag": "action", "actions": [
      { "tag": "button", "text": { "tag": "plain_text", "content": "Acknowledge" }, "type": "primary", "value": { "action": "ack", "alert_id": "def456" } },
      { "tag": "button", "text": { "tag": "plain_text", "content": "Escalate" }, "type": "danger", "value": { "action": "escalate", "alert_id": "def456" } },
      { "tag": "button", "text": { "tag": "plain_text", "content": "Resolved" }, "type": "default", "value": { "action": "resolve", "alert_id": "def456" } }
    ]}
  ]
}
```

**P2 Card (non-urgent):**

```json
{
  "config": { "wide_screen_mode": true },
  "header": {
    "title": { "tag": "plain_text", "content": "P2: Heartbeat reliability score dropping" },
    "template": "yellow"
  },
  "elements": [
    { "tag": "div", "text": { "tag": "lark_md", "content": "**Agent:** boss-2\n**Score:** 62 (unstable)\n**Window:** last 30 min\n**Trend:** dropping 12 points per hour\n**Dashboard:** [Grafana link](...)" } }
  ]
}
```

**P3 Daily Digest Card (blue):**

```json
{
  "config": { "wide_screen_mode": true },
  "header": {
    "title": { "tag": "plain_text", "content": "Daily Alert Digest -- May 23" },
    "template": "blue"
  },
  "elements": [
    { "tag": "div", "text": { "tag": "lark_md", "content": "**Summary (last 24h):**\n- Total alerts: 14\n- P0: 0 | P1: 2 | P2: 5 | P3: 7\n- Acknowledged: 12/14 (85.7%)\n- MTTA (P1): 4m 30s\n- Handover: See notes below\n\n**Services with most alerts:**\n1. cc-connect: 4 (all resolved)\n2. Disk usage: 3 (2 acknowledged, 1 pending)\n\n**Active incidents:**\n- Disk usage on sim (P1, unacknowledged, 23m)" } }
  ]
}
```

### 2.4 On-Call Roster Data Source

The on-call roster lives in ClickHouse, populated by a management script or Feishu form. It is the **single source of truth** for `@on-call` resolution.

```sql
CREATE TABLE infra.oncall_roster (
    date            Date,
    shift           LowCardinality(String),       -- "primary" / "secondary"
    user_id         String,                        -- Feishu user ID (ou_xxx)
    user_name       String,                        -- display name
    feishu_open_id  String,                        -- Feishu open ID for @mention
    start_time      DateTime,
    end_time        DateTime,
    note            String,                        -- shift-specific notes
    created_at      DateTime DEFAULT now(),
    updated_at      DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (date, shift)
TTK date + INTERVAL 90 DAY DELETE;

-- Populated daily at 00:00 by the schedule manager
-- The primary and secondary roles are decided weekly by the on-call coordinator
```

**Lookup query (used by feishu-bridge to resolve @on-call):**

```sql
-- Who is on call right now?
SELECT feishu_open_id
FROM infra.oncall_roster
WHERE date = today()
  AND shift = 'primary'
  AND start_time <= now()
  AND end_time >= now()
LIMIT 1;
```

### 2.5 Feishu Bot Implementation

The existing `feishu-bridge` service (see `docs/infra/reviews/review-bridge-ck-ingestion-A1.md`) is extended with:

1. **AlertManager webhook receiver** -- listens on `/webhook/alertmanager`, parses the alert payload
2. **Card builder** -- templates per severity (Section 2.3)
3. **On-call resolver** -- queries `infra.oncall_roster` to find current on-call user
4. **Message sender** -- posts card via Feishu SendMessage API (`/open-apis/im/v1/messages`)
5. **Action handler** -- receives button clicks via `/webhook/action` endpoint, processes acks/escalations/silences

**Endpoint summary:**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/webhook/alertmanager` | POST | Receive AlertManager alert webhook |
| `/webhook/action` | POST | Receive Feishu interactive card callback |
| `/api/oncall/current` | GET | Return current on-call info (for dashboards) |
| `/api/oncall/schedule` | POST | Update on-call roster (manual or via script) |

### 2.6 Grafana -> Feishu Routing

Grafana alert notifications route through AlertManager, not directly to Feishu. This ensures a single routing point:

```
Grafana Alert ──> AlertManager ──> feishu-bridge webhook ──> Feishu card
```

**Grafana AlertManager config:**

```yaml
# /etc/alertmanager/alertmanager.yml
route:
  receiver: feishu-bridge-webhook
  group_by: ['alertname', 'cluster']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: 'feishu-bridge-webhook'
    webhook_configs:
      - url: 'http://feishu-bridge:8080/webhook/alertmanager'
        send_resolved: true
```

This keeps the routing logic in one place. Grafana itself does not need to know about on-call schedules or Feishu groups.

---

## 3. Escalation Policy

### 3.1 Escalation Levels

Three levels of escalation. Each level has a time budget. If the responder at the current level does not acknowledge within the budget, the alert escalates to the next level.

```
Level 0: Primary on-call
   Budget: 5 min (P0) / 15 min (P1)
   Action: Tries to acknowledge
   └── Missing budget ──>
Level 1: Secondary on-call
   Budget: 5 min (P0) / 15 min (P1)
   Action: Tries to acknowledge
   └── Missing budget ──>
Level 2: All engineers + Boss (TTS)
   Budget: Immediate
   Action: Any acknowledgement resolves escalation
   └── Missing budget ──>
Level 3: Site-wide incident declared
   Budget: N/A
   Action: Emergency bridge, all hands
```

### 3.2 Time Budgets by Severity

| Level | P0 Budget | P1 Budget | P2 Budget | P3 |
|-------|-----------|-----------|-----------|---|
| L0 (Primary) | 5 min | 15 min | 1 hour (business hours only) | N/A (no live alert) |
| L1 (Secondary) | 5 min | 15 min | No escalation | N/A |
| L2 (@all + Boss) | Immediate | 15 min | N/A | N/A |
| L3 (Incident declared) | Immediate | N/A | N/A | N/A |

### 3.3 Escalation Engine

The escalation engine runs as a lightweight process inside `feishu-bridge`. For each unacknowledged alert, it tracks:

```sql
CREATE TABLE infra.escalation_state (
    alert_id        String,
    fingerprint     String,                     -- AlertManager dedup fingerprint
    severity        LowCardinality(String),
    fired_at        DateTime64(3),
    acknowledged_at Nullable(DateTime64(3)),
    escalate_level  UInt8 DEFAULT 0,            -- 0=primary, 1=secondary, 2=all, 3=incident
    escalate_at     Nullable(DateTime64(3)),    -- next escalation time
    resolved_at     Nullable(DateTime64(3)),
    resolution      Nullable(String),           -- "acknowledged" / "auto_resolved" / "silenced"
    notify_count    UInt8 DEFAULT 0,            -- how many times we've re-notified
    _updated_at     DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(_updated_at)
ORDER BY (alert_id);
```

**Escalation loop** (runs every 60s on feishu-bridge):

```python
# Pseudocode for the escalation tick
def escalation_tick():
    # Get unacknowledged alerts past their escalation deadline
    pending = query("""
        SELECT alert_id, severity, escalate_level, fired_at
        FROM infra.escalation_state
        WHERE acknowledged_at IS NULL
          AND resolved_at IS NULL
          AND escalate_at <= now()
        ORDER BY severity, fired_at
    """)

    for alert in pending:
        if alert.escalate_level == 0:
            # Escalate primary -> secondary
            notify_secondary(alert)
            update_escalation(
                alert_id=alert.alert_id,
                escalate_level=1,
                escalate_at=now() + budget(alert.severity, level=1)
            )
        elif alert.escalate_level == 1:
            # Escalate secondary -> @all
            notify_all_engineers(alert)
            update_escalation(
                alert_id=alert.alert_id,
                escalate_level=2,
                escalate_at=now() + budget(alert.severity, level=2)
            )
        elif alert.escalate_level == 2:
            # Escalate to incident (TTS to boss)
            declare_incident(alert)
            update_escalation(
                alert_id=alert.alert_id,
                escalate_level=3,
                escalate_at=None  # terminal
            )
```

### 3.4 Escalation Notification Content

Each escalation level sends a progressively more urgent message:

**Level 0 -> 1 (primary missed):**

> P0 alert `cc-connect down` was not acknowledged by Primary (dongqs) within 5 minutes.
> Escalating to Secondary (@luna).
> @luna Please acknowledge immediately.

**Level 1 -> 2 (secondary missed):**

> P0 alert `cc-connect down` was not acknowledged by Secondary either.
> @all ALL ENGINEERS - P0 alert requires immediate attention.

**Level 2 -> 3 (all missed, incident declared):**

> INCIDENT DECLARED: P0 alert `cc-connect down` unacknowledged for 15+ minutes.
> All escalation levels exhausted. TTS notification sent to Boss.
> Emergency response required.

### 3.5 Escalation Suppression

Escalation is suppressed when:

- The alert is acknowledged (any level) -- escalation stops immediately
- The alert resolves automatically -- escalation state is cleaned up
- A silence is placed covering the alert -- escalation stops for the silence duration
- The cluster is in maintenance mode (`.kyb-diaries/.maintenance-mode`) -- escalation is downgraded to P3

### 3.6 Escalation After Hours

Outside business hours (20:00-09:00 Asia/Shanghai, weekends), time budgets are relaxed:

| Level | P0 (after hours) | P1 (after hours) |
|-------|-------------------|-------------------|
| L0 (Primary) | 10 min | 30 min |
| L1 (Secondary) | 10 min | 30 min |
| L2 (@all) | 5 min | 15 min |

This accounts for the higher likelihood that the on-call engineer is asleep or away from keyboard. The secondary budget is the same as primary -- no point rushing to secondary if the primary might just be slow to wake up.

---

## 4. Alert Acknowledgement Tracking

### 4.1 Acknowledgement Flow

```
Alert fires ──> Card posted to Feishu ──> User clicks "Acknowledge"
                                              │
                                              ├── Button click → feishu-bridge /webhook/action
                                              ├── Sets acknowledged_at in infra.alerts
                                              ├── Updates infra.escalation_state (stops escalation)
                                              ├── Sends confirmation to Feishu thread
                                              └── Logs event to infra.acknowledgement_log
```

### 4.2 Acknowledgement Data Model

Each acknowledgement is recorded in a dedicated table for audit and MTTA computation:

```sql
CREATE TABLE infra.acknowledgement_log (
    alert_id        String,
    fingerprint     String,
    acked_by        String,                    -- Feishu user ID
    acked_by_name   String,                    -- display name
    acked_at        DateTime64(3),
    method          LowCardinality(String),    -- "feishu_button" / "api" / "auto"
    escalation_level UInt8,                    -- which level caught it (0=primary timely, 1=escalated to secondary, etc.)
    response_time_seconds UInt32,              -- fired_at -> acked_at
    note            String,                    -- optional user note
    _inserted_at    DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (toDate(acked_at), alert_id);
```

### 4.3 MTTA Computation

MTTA is computed per alert instance and aggregated per shift:

**Per-alert MTTA:**
```sql
-- Response time per alert
SELECT alert_id, severity,
       dateDiff('second', fired_at, acked_at) AS mtta_seconds
FROM infra.acknowledgement_log
WHERE acked_at > now() - INTERVAL 7 DAY;
```

**Per-shift MTTA summary:**
```sql
-- Automatically generated at handover
SELECT '2026-05-23' AS shift_date,
       severity,
       count() AS alerts,
       avg(response_time_seconds) AS avg_mtta,
       quantile(0.5)(response_time_seconds) AS p50_mtta,
       quantile(0.9)(response_time_seconds) AS p90_mtta,
       min(response_time_seconds) AS min_mtta,
       max(response_time_seconds) AS max_mtta
FROM infra.acknowledgement_log
WHERE toDate(acked_at) = '2026-05-23'
GROUP BY severity;
```

### 4.4 Acknowledgement Status Board

A Grafana dashboard panel shows real-time acknowledgement status for all active (firing, unacknowledged) alerts:

| Alert | Severity | Fired At | Age | Status | Escalation Level | Response Time (if acked) |
|-------|----------|----------|-----|--------|-----------------|--------------------------|
| cc-connect down | P0 | 14:22:30 | 3m 12s | NOT ACKED | L0 (primary) | -- |
| Disk 87% | P1 | 14:20:00 | 5m 42s | ACKED by dongqs | L0 | 1m 30s |
| HB score drop | P2 | 14:00:00 | 26m | ACKED by luna | L1 (secondary) | 12m |

**Status logic:**
- `NOT ACKED` if `acknowledged_at IS NULL AND resolved_at IS NULL` in `infra.escalation_state`
- `ACKED by <user>` if `acknowledged_at IS NOT NULL`
- `ESCALATING` if escalate_level > 0 and not yet acknowledged
- `RESOLVED` if resolved_at is set

### 4.5 Measurable Goals

| Metric | Target | Measurement |
|--------|--------|-------------|
| P0 MTTA (P50) | < 5 min | `p50_mtta` from per-shift summary |
| P0 MTTA (P90) | < 15 min | `p90_mtta` from per-shift summary |
| P1 MTTA (P50) | < 15 min | Same query |
| P1 acknowledgement rate | 100% (every P1 must be acked) | `count(acked) / count(fired)` per shift |
| Escalation rate | < 10% of alerts escalate beyond L0 | `count(escalate_level > 0) / count(total)` |
| Unacknowledged P0/P1 | 0 at handover | Query `infra.escalation_state` at shift end |

---

## 5. Handover Notes

### 5.1 Handover Trigger

A handover happens when the primary on-call shift ends. This can be:

- **Scheduled:** Every day at a fixed time (e.g., 20:00 Asia/Shanghai)
- **Ad-hoc:** When the on-call engineer needs to step away temporarily
- **Emergency:** When the on-call engineer is part of an incident and needs relief

### 5.2 Handover Document Format

At the end of each shift, the outgoing on-call engineer generates a structured handover note. This is posted to the Feishu on-call group and stored in ClickHouse.

```markdown
## On-Call Handover -- 2026-05-23

### Outgoing: dongqs (primary)
### Incoming: luna (primary)

---

### Shift Summary
- Duration: 08:00 - 20:00 (12h)
- Total alerts: 14
  - P0: 0
  - P1: 2
  - P2: 5
  - P3 (digest): 7
- Acknowledged: 12/14 (85.7%)
- MTTA: P1 avg 4m 30s

### Active Incidents
- **Disk usage on sim (P1)** -- unacknowledged, 23m active
  - Context: Disk grew from 72% to 87% at 19:40. Auto-cleanup triggered but did not reclaim enough.
  - Action taken: Ran `docker system prune -f`, freed 3GB. Waiting for next patrol check.
  - Pending: If not resolved by 21:00, SSH in and check `/var/log` for large log files.

### Resolved Incidents
- **cc-connect restart loop (P0)** -- 14:22 to 14:35 (13 min)
  - Root cause: OOM killed by systemd. Increased memory limit from 512M to 1G.
  - Verification: cc-connect uptime 6h, stable.
  - Runbook updated: Yes.

### Notes for Incoming
1. **sing-box** has been flapping since 18:00. 3 restarts in 2h. Possible DNS issue.
   - Check: `docker logs kyb-infra-sing-box --tail 50 | grep -i error`
   - Known workaround: `docker restart kyb-infra-sing-box` (fixes for ~1h)
   - Related issue: #oncall-42
2. **Kafka consumer lag** on cc-connect-topic spiked to 1500 at 16:00 but recovered on its own.
   - Monitor for next 2h. If it spikes again, increase partitions.
3. **nuc8** had a heartbeat miss at 19:10. Marked as `degraded`. No action needed unless second miss in 30 min.

### Action Items
- [ ] Check sim disk at 21:00 (see active incident)
- [ ] Investigate sing-box DNS issue tomorrow morning (#oncall-42)
- [ ] Follow up on Kafka consumer group rebalance (low priority)
- [ ] Review Grafana dashboard for error budget (Kafka at 42% remaining, trending down)

### Maintenance Window
- No planned maintenance for next 12h.
```

### 5.3 ClickHouse Handover Table

```sql
CREATE TABLE infra.oncall_handover (
    id                UInt64 AUTO_INCREMENT,
    shift_date        Date,
    outgoing_user     String,                   -- Feishu user ID
    incoming_user     String,
    created_at        DateTime64(3) DEFAULT now(),

    -- Summaries (auto-generated)
    total_alerts      UInt16,
    p0_count          UInt8,
    p1_count          UInt8,
    p2_count          UInt8,
    acknowledged_count UInt16,
    mtta_p0_avg       UInt32,                   -- seconds
    mtta_p1_avg       UInt32,
    escalation_count  UInt8,

    -- Active incidents (JSON array)
    active_incidents  String,                   -- JSON
    resolved_incidents String,                  -- JSON

    -- Human notes
    notes_for_incoming String,
    action_items      String,
    maintenance_window String,
    raw_markdown     String,                    -- full handover doc

    _inserted_at     DateTime DEFAULT now()
) ENGINE = MergeTree
ORDER BY (shift_date, outgoing_user);
```

### 5.4 Handover Workflow

```
[Scheduled] ──> 19:45: feishu-bridge sends reminder to primary
                    "Your shift ends in 15 minutes. Generate handover?"
                    [Generate Handover] [Dismiss]

    20:00: Primary clicks "Generate Handover"
           └── feishu-bridge auto-generates:
                ├── Shift summary (from infra.acknowledgement_log)
                ├── Active incidents (from infra.escalation_state)
                ├── Resolved incidents (from infra.acknowledgement_log)
                └── MTTA stats (from per-shift query)

          Primary edits draft, adds notes and action items
          Primary posts to group
          └── feishu-bridge stores in infra.oncall_handover
          └── feishu-bridge switches @on-call to incoming user
          └── @incoming is mentioned: "You're now on call until 08:00 tomorrow"
```

### 5.5 Emergency Handover

If the primary needs to step away mid-shift (e.g., personal emergency):

1. Primary posts `!handover emergency` in the on-call Feishu group
2. feishu-bridge immediately switches @on-call to secondary
3. Secondary receives a notification: "Emergency handover from dongqs. You are now primary."
4. The supervisor (or next available) is notified to find replacement for secondary slot
5. Full handover notes are generated within 30 minutes (post-hoc)

---

## 6. Schedule Management

### 6.1 Schedule Default

With a small team (currently ~2-3 engineers), a simple weekly rotation is sufficient:

| Week | Primary | Secondary |
|------|---------|-----------|
| Week A | dongqs | luna |
| Week B | luna | dongqs |
| Week C | dongqs | aoyama |
| Week D | aoyama | dongqs |

The schedule is maintained in `infra.oncall_roster` and managed via a script.

### 6.2 Schedule Management Script

```bash
# ~/.kyb/bin/oncall-schedule
# Manage on-call schedule in ClickHouse

# Set this week's schedule
oncall-schedule set --week 2026-W21 --primary dongqs --secondary luna

# View current schedule
oncall-schedule current

# View upcoming
oncall-schedule next --weeks 4

# Override for a specific date (ad-hoc)
oncall-schedule override --date 2026-05-25 --primary aoyama
```

### 6.3 Schedule Management via Feishu

For non-CLI users, schedule changes can be made via Feishu interactive card:

```
/oncall schedule --week 2026-W21 --primary dongqs --secondary luna
```

The bot responds with:

```
Week 21 (May 23 - May 29)
  Primary: dongqs
  Secondary: luna
  [Confirm] [Edit]
```

### 6.4 Feishu On-Call Group Roster Sync

The `@on-call` tag in Feishu groups requires a configured roster. The feishu bridge should periodically sync the on-call roster from ClickHouse to the Feishu group's on-call setting:

```
Every 1h:
  For each alert group:
    1. Query infra.oncall_roster for today's primary
    2. Update Feishu group's on-call roster via Feishu API
    3. Verify: tag @on-call resolves to the correct person
```

---

## 7. Grafana Integration

### 7.1 On-Call Dashboard

A dedicated Grafana dashboard for the on-call engineer:

```
Row: "Current Status"
  ├── Stat: Active Alerts (unacknowledged P0/P1)
  ├── Stat: Current On-Call (name + shift start time)
  ├── Stat: MTTA (P50 today)
  └── Stat: Alerts This Shift

Row: "Active Alerts"
  └── Table: All firing unacknowledged alerts
        (alertname, severity, age, escalation level, link to Feishu thread)

Row: "Shift Performance"
  ├── Time Series: MTTA over current shift (P50, P90 per hour)
  ├── Time Series: Alert count per hour (stacked by severity)
  └── Stat: Escalation rate this shift

Row: "Handover Helper"
  ├── Table: Resolved incidents this shift
  ├── Table: Notes for next shift (from handover table)
  └── Button: "Generate Handover" (links to feishu-bridge API)
```

### 7.2 Grafana On-Call Alert Notification

Grafana's built-in on-call integration is not used. Instead, all Grafana alert notifications route through AlertManager (Section 2.6). This keeps the on-call routing, escalation, and acknowledgement logic in one place (feishu-bridge).

If Grafana On-Call (Grafana's own on-call management product) is considered in the future, the existing ClickHouse-based roster can be used as a data source.

### 7.3 AlertManager Config for Grafana Alerts

```yaml
# Grafana alert rules forward to AlertManager
# This is Grafana's contact point config (via API or UI):

contact_point:
  name: "AlertManager"
  type: alertmanager
  settings:
    url: "http://alertmanager:9093"
```

AlertManager then routes based on severity labels added by Grafana:

```yaml
route:
  match:
    source: grafana
  receiver: feishu-bridge-webhook
  routes:
    - match:
        severity: P0
      repeat_interval: 5m
    - match:
        severity: P1
      repeat_interval: 15m
```

---

## 8. Implementation Phases

### Phase 1: Foundation (Week 1)

- [ ] Deploy `infra.oncall_roster` table in ClickHouse
- [ ] Deploy `infra.escalation_state` table in ClickHouse
- [ ] Deploy `infra.acknowledgement_log` table in ClickHouse
- [ ] Deploy `infra.oncall_handover` table in ClickHouse
- [ ] Add AlertManager webhook receiver endpoint to feishu-bridge (`/webhook/alertmanager`)
- [ ] Implement Feishu card templates (P0, P1, P2, P3 digest)
- [ ] Implement `@on-call` resolution from `infra.oncall_roster`
- [ ] Configure AlertManager to forward all alerts to feishu-bridge webhook

### Phase 2: Escalation (Week 2)

- [ ] Implement escalation engine (60s tick loop in feishu-bridge)
- [ ] Implement button actions: Acknowledge, Escalate, Silence, Resolve
- [ ] Configure escalation time budgets per severity (Section 3.2)
- [ ] Test escalation flow end-to-end: fire alert -> miss P0 budget -> secondary notified
- [ ] Implement escalation suppression (maintenance mode, silence, auto-resolve)
- [ ] Add after-hours budget relaxation

### Phase 3: Handover & Schedule (Week 3)

- [ ] Implement handover generation (auto-populate summary from ClickHouse queries)
- [ ] Implement handover posting to Feishu group
- [ ] Implement `oncall-schedule` CLI script
- [ ] Implement scheduled handover reminder (19:45 reminder for 20:00 shift end)
- [ ] Implement emergency handover flow (`!handover emergency`)
- [ ] Implement Feishu group on-call roster sync

### Phase 4: Dashboard & Reporting (Week 4)

- [ ] Build Grafana on-call dashboard (Section 7.1)
- [ ] Add Grafana panels for MTTA tracking per shift
- [ ] Add Grafana panels for escalation rate tracking
- [ ] Add daily digest generation (P3 card)
- [ ] Send handover notes into ClickHouse store
- [ ] Add on-call shift report to weekly review

### Phase 5: Polish (Ongoing)

- [ ] Measure MTTA against targets (Section 4.5)
- [ ] Tune escalation budgets based on real data
- [ ] Review handover quality: are action items actually getting done?
- [ ] Consider Feishu calendar integration for schedule auto-population
- [ ] Add TTS via `kyb notify` for P0 escalation to incident level

---

## 9. Runbook

### 9.1 Starting a Shift

```bash
# As the incoming on-call:
# 1. Check current state
feishu-bridge api /api/oncall/current
# Returns: {"primary": "dongqs", "secondary": "luna", "active": 2, "unacked": 1}

# 2. Read handover notes from previous shift
clickhouse-client --query "
  SELECT raw_markdown FROM infra.oncall_handover
  WHERE shift_date = yesterday()
  ORDER BY created_at DESC LIMIT 1;
"

# 3. Open Grafana on-call dashboard
# 4. Confirm roster is correct
oncall-schedule current
```

### 9.2 Acknowledging an Alert

**Via Feishu:** Click the "Acknowledge" button on the alert card.

**Via API (from scripts or patrol):**
```bash
curl -X POST http://feishu-bridge:8080/api/ack \
  -H "Content-Type: application/json" \
  -d '{"alert_id": "abc123", "acked_by": "dongqs", "method": "api", "note": "investigating"}'
```

### 9.3 Escalating Manually

If an alert needs more attention than the current level can provide:

```bash
# Via Feishu card button: click "Escalate"
# Or via API:
curl -X POST http://feishu-bridge:8080/api/escalate \
  -d '{"alert_id": "abc123", "reason": "needs senior investigation"}'
```

### 9.4 Generating a Handover

```bash
# Manual via API:
curl -X POST http://feishu-bridge:8080/api/handover/generate \
  -d '{"outgoing": "dongqs", "incoming": "luna", "notes": "See notes below"}'

# Auto-triggered at 19:45 daily
# Ad-hoc:
oncall-schedule handover --outgoing dongqs --incoming aoyama
```

### 9.5 Emergency: On-Call Unreachable

If the on-call engineer is completely unreachable (no Feishu response, phone not answered):

1. `oncall-schedule override --date today --primary luna` (switch to secondary)
2. Post in group: `!handover emergency`
3. Manually trigger escalation for any active unacknowledged P0/P1 alerts
4. Super-boss dispatches someone to investigate
5. After resolution: post-mortem on why on-call was unreachable

### 9.6 Testing the Escalation Chain

```bash
# Fire a test P0 alert to verify the full chain
# (Must be done in a test environment or during a known maintenance window)

curl -X POST http://alertmanager:9093/api/v1/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "severity": "P0",
      "instance": "test-boss"
    },
    "annotations": {
      "summary": "TEST ALERT - do not respond",
      "runbook": "docs/infra/runbooks/test.md"
    }
  }]'

# Expected:
# 0s: P0 card posted to Feishu group, @all
# 5m: Escalation L0 -> L1 (if unacknowledged), secondary notified
# 10m: Escalation L1 -> L2, @all
# 15m: Escalation L2 -> L3, incident declared
```

## Appendix A: Related Documents

- `docs/infra/reviews/alert-fatigue.md` -- alert fatigue monitoring (shared `infra.alerts` table)
- `docs/infra/reviews/error-budget.md` -- SLO/SLI error budget tracking (alert severity classification used here)
- `docs/infra/reviews/review-bridge-ck-ingestion-A1.md` -- feishu-bridge service architecture
- `docs/infra/reviews/review-bridge-hooks-C1.md` -- cc-connect hooks and Feishu message format
- `docs/infra/reviews/heartbeat-reliability.md` -- patrol heartbeat scoring (on-call receives reliability alerts)
- `docs/infra/reviews/session-monitor.md` -- cc-connect session monitoring (alerts route through this system)
- `docs/infra/observability-design.md` -- overall observability architecture
- `docs/infra/multi-cluster-boss-architecture.md` -- multi-cluster infra structure on-call covers
- `docs/infra/5min-patrol-guide.md` -- patrol system (on-call monitors patrol reliability)

## Appendix B: Feishu API Reference

| API | Method | Endpoint | Used For |
|-----|--------|----------|----------|
| Send Message | POST | `/open-apis/im/v1/messages` | Posting alert cards to group |
| Update Message | PATCH | `/open-apis/im/v1/messages/:id` | Updating card with ack status |
| Get Group Info | GET | `/open-apis/im/v1/chats/:id` | Checking group members |
| Set On-Call | POST | `/open-apis/calendar/v4/oncall` | Syncing Feishu on-call roster |
| Interactive Callback | POST | (webhook) | Receiving button clicks from cards |

> **Note:** Feishu API endpoints are versioned and may need updating. Check the latest Feishu Open API docs when implementing.

---

> **Summary:** This document defines a complete on-call integration for the kyb infra alerting system, using Feishu as the primary notification channel. The system provides multi-level escalation, acknowledgement tracking with MTTA metrics, structured handover notes, and a ClickHouse-backed roster. It builds on the existing feishu-bridge service and shares the `infra.alerts` table with the alert fatigue monitoring system.

> ／人◕ ‿‿ ◕人＼
