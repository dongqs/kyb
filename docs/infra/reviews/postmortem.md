---
decision: 稍后做
---

# Post-Mortem Tracking for Incidents

> **Status:** Practical Design Document
> **Date:** 2026-05-23
> **Context:** Standardized process for incident post-mortems, action item tracking, review cadence, and a searchable lessons learned database.

---

## Table of Contents

1. [Principles](#1-principles)
2. [When to Write a Post-Mortem](#2-when-to-write-a-post-mortem)
3. [Post-Mortem Template](#3-post-mortem-template)
4. [Severity and Response Tiers](#4-severity-and-response-tiers)
5. [Action Item Tracking](#5-action-item-tracking)
6. [Review Frequency and Cadence](#6-review-frequency-and-cadence)
7. [Lessons Learned DB](#7-lessons-learned-db)
8. [Post-Mortem ClickHouse Schema](#8-post-mortem-clickhouse-schema)
9. [Grafana Dashboard](#9-grafana-dashboard)
10. [Blameless Culture Rules](#10-blameless-culture-rules)
11. [Workflow Automation](#11-workflow-automation)
12. [Related Documents](#12-related-documents)

---

## 1. Principles

### 1.1 Why Post-Mortems

Post-mortems convert incidents into organizational learning. Every incident is a free test of the system under failure conditions. Without a post-mortem, that test teaches only the individuals involved. With a post-mortem, the whole team learns.

### 1.2 Blameless Foundation

Post-mortems are **blameless by design**. The root cause is never "a person made a mistake." The root cause is always a process, tool, or system gap that allowed that mistake to happen or failed to catch it.

- If someone ran the wrong command: why was there no guardrail?
- If someone misread a dashboard: why was the dashboard ambiguous?
- If someone deployed bad config: why wasn't there a pre-commit check?

### 1.3 Post-Mortem Lifecycle

```
Incident occurs
    │
    ▼
Severity assessment ──→ No post-mortem needed (tier 3)
    │
    ▼
Post-mortem drafted (within timeline per tier)
    │
    ▼
Peer review (at least one other engineer reads it)
    │
    ▼
Action items created (tracked to closure)
    │
    ▼
Lessons learned entered into DB
    │
    ▼
Review at next retro / review meeting
    │
    ▼
Action items closed → verified
```

### 1.4 Post-Mortem vs Incident Report

| Aspect | Incident Report | Post-Mortem |
|--------|----------------|-------------|
| Purpose | Document what happened in real-time | Learn why it happened and prevent recurrence |
| Audience | On-call, incident responders | Whole team, future engineers |
| Timeline | Written during / immediately after incident | Written 24h-5d after incident |
| Depth | Timeline and actions taken | Root cause, contributing factors, systemic gaps |
| Blame | None | None (explicit) |
| Action items | Tactical (fix the immediate issue) | Strategic (prevent class of issues) |

---

## 2. When to Write a Post-Mortem

### 2.1 Mandatory Triggers

A post-mortem is **required** when any of these conditions are met:

- **P0 or P1 incident** (see severity tiers below)
- **P2 incident** that resulted in user-facing impact or data loss
- **Error budget consumed > 10%** in a single incident for a Tier-0 or Tier-1 service
- Any incident where the **same root cause** caused a previous incident (repeat failure)
- Customer-visible outage lasting > 5 minutes
- Security incident (any severity)

### 2.2 Discretionary Triggers

The on-call engineer or team lead can request a post-mortem for:

- P2 incidents with interesting failure modes
- Near-misses (manual intervention prevented outage)
- Infrastructure changes that surprised the team (e.g., config behaved unexpectedly)
- Chronic minor issues that collectively degrade reliability

### 2.3 Decision Flow

```
Incident resolved
    │
    ├── Is it P0/P1? → Post-mortem mandatory
    │
    ├── Is it P2 with user impact? → Post-mortem mandatory
    │
    ├── Is it a repeat of a previous root cause? → Post-mortem mandatory
    │
    ├── Is it P2 without user impact? → Discretionary (lead decides)
    │
    └── Is it P3? → No post-mortem, but log to diary for trends
```

---

## 3. Post-Mortem Template

### 3.1 Template File

Each post-mortem is a markdown file stored at `docs/infra/postmortems/YYYY-MM-DD-short-description.md`.

```markdown
# Post-Mortem: <Brief Title>

**Date:** YYYY-MM-DD
**Author:** <name>
**Reviewer:** <name>
**Status:** Draft | Reviewed | Actions In Progress | Closed
**Incident ID:** <link to incident in tracking system>
**Severity:** P0 | P1 | P2

## Summary

One paragraph describing the incident in plain language: what broke, who was affected, for how long.

## Impact

| Metric | Value |
|--------|-------|
| Duration | <start> to <end> (Xh Ym) |
| Users affected | <number> |
| Error budget consumed | <X%> of <service> 30d budget |
| Data loss | Yes / No (if yes, describe extent) |
| Financial impact | <estimate if applicable> |
| MTTA | <time from detection to acknowledgment> |
| MTTR | <time from acknowledgment to mitigation> |

## Timeline

All times in Asia/Shanghai (UTC+8).

| Time | Event |
|------|-------|
| HH:MM | <What happened> |
| HH:MM | <Alert fired / detected by> |
| HH:MM | <Acknowledged by> |
| HH:MM | <Action taken> |
| HH:MM | <Action taken> |
| HH:MM | <Service restored> |
| HH:MM | <Incident declared resolved> |

Key observation markers in the timeline:
- **FIRST_FAILURE** — earliest observable symptom
- **DETECTION** — when the team became aware (alert / user report / patrol)
- **MITIGATION** — when the service was restored (not root cause fix, but impact stopped)
- **RESOLUTION** — when root cause was fixed and system returned to steady state

## Root Cause Analysis

### Direct Cause

<What specifically broke. One sentence. Example: "The ClickHouse merge tree ran out of disk space because the TTL purge job failed due to a permissions change.">

### Contributing Factors

1. <Factor 1: e.g., "No disk space alert for the ClickHouse data volume">
2. <Factor 2: e.g., "TTL job runs as root but data directory ownership changed during a container rebuild">
3. <Factor 3: e.g., "Disk usage trend was increasing for 72h but no one reviewed it">

### Why This Escalated

<Why was the incident more severe or longer-lasting than it should have been? Example: "The pager rotation had just changed, and the new on-call had never seen a ClickHouse disk-full scenario.">

### Detection Gap

<How was this detected? Could it have been detected earlier? What alert was missing or insufficient?>

## What Went Well

1. <Thing that worked well>
2. <Thing that worked well>
3. <Thing that worked well>

## What Went Wrong

1. <Thing that went wrong>
2. <Thing that went wrong>
3. <Thing that went wrong>

## Surprises

<What surprised the team? Unexpected behavior, assumptions that were wrong, system responses that were different from documented behavior.>

## Action Items

Each action item follows the format below. Action items are numbered sequentially (AI-001, AI-002, ...).

| ID | Action | Type | Owner | Priority | Linked Issue | Deadline | Status |
|----|--------|------|-------|----------|-------------|----------|--------|
| AI-001 | Add ClickHouse disk usage alert at 80% | preventive | @alice | P0 | <link> | YYYY-MM-DD | Open |
| AI-002 | Add disk trend panel to ClickHouse dashboard | monitoring | @bob | P1 | <link> | YYYY-MM-DD | Open |
| AI-003 | Document TTL job recovery procedure | process | @carol | P1 | <link> | YYYY-MM-DD | Open |

### Action Item Types

| Type | Meaning | Example |
|------|---------|---------|
| `preventive` | Prevents this exact root cause from recurring | Add validation, fix config |
| `detective` | Ensures root cause is detected faster next time | Add alert, add dashboard |
| `process` | Improves how the team responds or documents | Update runbook, add training |
| `systemic` | Addresses a class of issues, not just this one | Add pre-commit hook, add test |
| `mitigation` | Reduces blast radius if similar incident recurs | Add rate limiter, add circuit breaker |
| `followup` | Requires investigation or decision before preventive action can be taken | Research alternative, schedule refactor |

## Lessons Learned

<3-5 sentences summarizing the key takeaways. These are entered into the Lessons Learned DB (Section 7).>

1. <Lesson learned>
2. <Lesson learned>
3. <Lesson learned>

## Appendix

<Links to relevant dashboards, logs, code commits, config diffs, chat transcripts.>

- Grafana dashboard snapshot: <link>
- Relevant logs: <link>
- Fix commit: <commit hash>
- Incident chat thread: <link>
```

### 3.2 Minimal Template (P2, Non-Critical)

For discretionary post-mortems (P2, low impact), a shorter template:

```markdown
# Post-Mortem: <Brief Title>

**Date:** YYYY-MM-DD
**Author:** <name>
**Severity:** P2

## Summary
<One paragraph>

## Root Cause
<One sentence>

## Action Items
| ID | Action | Owner | Priority | Deadline | Status |
|----|--------|-------|----------|----------|--------|
| AI-001 | <action> | @who | P1 | YYYY-MM-DD | Open |

## Lessons Learned
<Key takeaways>
```

---

## 4. Severity and Response Tiers

### 4.1 Incident Severity Definition

| Severity | Definition | Example | Post-Mortem | Draft Deadline | Review Deadline |
|----------|-----------|---------|-------------|----------------|-----------------|
| **P0** | Complete service outage, data loss, or security breach | cc-connect down, ClickHouse data loss, credentials leaked | Mandatory | 48h | 72h |
| **P1** | Severe degradation for a subset of users or dependent services | Feishu bridge down, sing-box proxy failure for one region | Mandatory | 72h | 5d |
| **P2** | Partial degradation, single component failure, no user impact | Grafana dashboard slow, build runner queue backlog | Mandatory if user-facing; discretionary otherwise | 5d | 7d |
| **P3** | Minor issue, cosmetic, self-resolving | Transient latency spike, single scrape failure | None (log to diary only) | N/A | N/A |

### 4.2 Timeline Compliance

| Severity | Draft Deadline | Review Deadline | Total SLA |
|----------|---------------|-----------------|-----------|
| P0 | 48h post-resolution | 72h post-draft | 120h (5d) |
| P1 | 72h post-resolution | 5d post-draft | 8d |
| P2 (mandatory) | 5d post-resolution | 7d post-draft | 12d |

**Consequences of missing deadlines:**
- Draft overdue: auto-assign a co-author to help complete it
- Review overdue: escalate to team lead
- Both overdue: incident is flagged in weekly review until post-mortem is closed

---

## 5. Action Item Tracking

### 5.1 Lifecycle

```
Created (Open)
    │
    ▼
Assigned (In Progress)
    │
    ▼
Resolved (PR merged / config deployed / runbook published)
    │
    ▼
Verified (author or reviewer confirms fix is effective)
    │
    ▼
Closed
```

### 5.2 Action Item States

| State | Definition |
|-------|-----------|
| **Open** | Created, not yet started |
| **In Progress** | Owner assigned and working on it |
| **Resolved** | Fix implemented, PR merged, deployed |
| **Verified** | Post-resolution: confirmed fix works (monitored for X days, or tested) |
| **Closed** | Full lifecycle complete |
| **Won't Do** | Reviewed and decided not to pursue (must have reason documented) |

### 5.3 Priority Definitions

| Priority | Definition | Timeline | Escalation |
|----------|-----------|----------|------------|
| **P0** | Must fix immediately; same class of incident could recur | < 24h | Daily check-in |
| **P1** | Must fix before next incident review | < 7d | Weekly check-in |
| **P2** | Should fix; important but not blocking | < 30d | Monthly check-in |
| **P3** | Nice to have; no immediate risk | < 90d | Quarterly review |

### 5.4 Verifying Actions

Every action item must be verified before closing. Verification criteria depend on the type:

| Action Type | Verification Criteria |
|-------------|----------------------|
| preventive | Test that the failure scenario is now prevented (or caught by automation) |
| detective | Confirm the alert fires correctly when the condition is reproduced |
| process | Runbook has been followed by someone who hasn't seen it before (dry-run) |
| systemic | Pre-commit hook / CI check / lint rule blocks the problematic pattern |
| mitigation | Chaos engineering test confirms the mitigation works under load |

### 5.5 Stale Action Item Policy

| Condition | Action |
|-----------|--------|
| Open > 14d past deadline | Auto-ping owner in Feishu daily |
| Open > 30d past deadline | Escalate to team lead |
| Open > 60d past deadline | Move to Won't Do or justify extension in next review |
| Won't Do count per-incident > 3 | Flag in quarterly audit: are we avoiding hard fixes? |

### 5.6 Action Items as Code

Action items are tracked as GitLab issues with the label `postmortem-action`. Each action item issue contains:

- Title: `[PM-YYYY-MM-DD] AI-XXX: <action text>`
- Label: `postmortem-action`
- Milestone: sprint or month
- Assignee: owner
- Due date: from deadline
- Description: link to post-mortem file, context, verification criteria

```yaml
# Example: .gitlab/issue-templates/PostMortemAction.md
## Context
Link to post-mortem: <path>
Incident: <link>

## Acceptance Criteria
<How will we verify this is done?>

## Verification
- [ ] Implemented
- [ ] Tested
- [ ] Monitored for <X> days without regression
```

---

## 6. Review Frequency and Cadence

### 6.1 Weekly Incident Review

Every Monday, a 30-minute review of incidents from the previous week.

**Agenda:**
1. Review new post-mortems (draft status) — 10 min
2. Update open action items — 10 min
3. Identify trends (same service, same failure class, same time of day) — 5 min
4. Decide discretionary post-mortems for the week — 5 min

**Output:**
- Updated action item statuses
- New discretionary post-mortem assignments
- Trend observations logged to Lessons Learned DB (Section 7)

### 6.2 Monthly Deep-Dive Review

On the last Friday of each month, a 60-minute deep-dive.

**Agenda:**
1. Summary of all incidents this month (count, severity, total downtime) — 10 min
2. Top 3 most impactful incidents (detailed walkthrough) — 20 min
3. Action item completion rate (are we closing them?) — 5 min
4. Systemic issue identification (are there patterns across incidents?) — 15 min
5. Prioritize systemic fixes for next sprint — 10 min

**Output:**
- Monthly incident report (sent to team + stakeholders)
- Systemic improvement backlog items
- Updated SLO targets if warranted
- Top 3 patterns to watch next month

### 6.3 Quarterly Retrospective

Every quarter, a 90-minute session covering the big picture.

**Agenda:**
1. Incident count trend (quarter-over-quarter) — 10 min
2. Error budget consumption by service (which services are driving risk?) — 15 min
3. Action item closure rate + aging analysis — 10 min
4. Recurring failure class identification — 20 min
5. Post-mortem quality review (are we getting shallow? any blame language?) — 15 min
6. Process improvement proposals — 15 min
7. Action items for the next quarter — 5 min

**Output:**
- Quarterly reliability report
- Post-mortem process improvements (template updates, tooling changes)
- Updated runbooks
- Blameless culture pulse check

### 6.4 Annual Post-Mortem Audit

At year-end, a full audit of all post-mortems.

**Criteria:**
- **Coverage:** Did every P0/P1 incident have a post-mortem?
- **Quality:** Are root causes deep enough? (5 Whys applied?)
- **Closure:** What percentage of action items are closed? Average age of open items?
- **Repeats:** How many incidents had the same root cause as a previous one?
- **Trends:** Which failure classes are increasing? Which are decreasing?

**Output:**
- Annual reliability report
- Updated incident severity definitions if needed
- Infrastructure investment plan for the next year

---

## 7. Lessons Learned DB

### 7.1 What Goes Into the DB

Every post-mortem produces 3-5 "lessons learned" sentences. These are the distilled, one-sentence takeaways that would be useful to someone who wasn't involved in the incident.

Examples:
- "ClickHouse TTL purge runs as root; if data directory ownership changes, purge silently fails and disk fills up — always monitor TTL execution time."
- "PostgreSQL replication lag alert at 10s is too sensitive for batch workloads; change to 60s with 5-minute evaluation window."
- "Docker container restart during deploy can cause connection pool exhaustion if the pool warm-up period overlaps with traffic spike."

### 7.2 ClickHouse Table for Lessons

Lessons are stored in ClickHouse for queryability:

```sql
CREATE TABLE infra.lessons_learned (
    id              UUID DEFAULT generateUUIDv4(),
    created_at      DateTime DEFAULT now(),
    incident_date   Date,
    incident_id     String,           -- Link to incident tracking
    postmortem_path String,           -- Relative path in docs/
    severity        LowCardinality(String),
    service         LowCardinality(String),
    cluster         LowCardinality(String),
    failure_class   LowCardinality(String),
    lesson          String,           -- The distilled lesson (one sentence)
    context         String,           -- More detail if needed
    tags            Array(String),    -- Categorization tags

    -- Action item linkage
    has_action_item Bool DEFAULT true,
    action_item_ids Array(String),    -- AI-001, AI-002, etc.
    action_item_status String DEFAULT 'open',  -- all_closed / some_open / none

    -- Attribution
    author          LowCardinality(String),
    reviewer        LowCardinality(String)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(incident_date)
ORDER BY (incident_date, service, failure_class)
TTL incident_date + INTERVAL 3 YEAR DELETE
```

### 7.3 Failure Class Taxonomy

Every lesson is tagged with a failure class. This enables trend analysis across incidents.

| Failure Class | Description | Examples |
|---------------|-------------|----------|
| `resource_exhaustion` | Ran out of capacity | Disk full, OOM, connection pool exhausted |
| `config_error` | Misconfiguration or bad deploy | Wrong YAML, missing env var, bad flag |
| `dependency_failure` | External service degraded | PostgreSQL down, ClickHouse slow, network partition |
| `deploy_regression` | Code change caused issue | Memory leak in new version, API contract break |
| `alert_missing` | Should have been detected but wasn't | No disk alert, no error rate monitoring |
| `alert_noise` | Alert existed but was ignored due to fatigue | Threshold too low, false positives |
| `runbook_stale` | Procedure was wrong or missing | Old connection string, wrong recovery steps |
| `capacity_planning` | Insufficient capacity for growth | Traffic spike exceeded provisioned resources |
| `human_error` | Someone did something unexpected | Wrong command, wrong instance, wrong env |
| `race_condition` | Timing-dependent failure | Concurrent operations, async ordering |
| `security` | Security-related | Credential leak, unauthorized access |
| `data_corruption` | Data integrity issue | Wrong data written, index corruption |
| `design_flaw` | Systemic design issue | Single point of failure, no graceful degradation |

### 7.4 Query Examples

```sql
-- All lessons for a specific service
SELECT lesson, incident_date, failure_class
FROM infra.lessons_learned
WHERE service = 'cc-connect'
ORDER BY incident_date DESC;

-- Most common failure classes
SELECT failure_class, count(*) AS cnt
FROM infra.lessons_learned
WHERE created_at > now() - INTERVAL 90 DAY
GROUP BY failure_class
ORDER BY cnt DESC;

-- Incidents with open action items
SELECT lesson, action_item_ids
FROM infra.lessons_learned
WHERE action_item_status = 'some_open';

-- Lessons with no associated action item (potential gap)
SELECT lesson, incident_date, postmortem_path
FROM infra.lessons_learned
WHERE has_action_item = false;

-- Find all lessons by keyword (e.g., "ClickHouse")
SELECT lesson, incident_date, service, failure_class
FROM infra.lessons_learned
WHERE lesson ILIKE '%ClickHouse%';

-- Repeat failure classes (same class > 2 times for same service)
SELECT service, failure_class, count(*) AS cnt
FROM infra.lessons_learned
GROUP BY service, failure_class
HAVING cnt > 2
ORDER BY cnt DESC;
```

### 7.5 CLI Entry

```bash
# Add a lesson after post-mortem review
kyb lesson add \
  --incident-date 2026-05-23 \
  --incident-id "INC-042" \
  --postmortem "docs/infra/postmortems/2026-05-23-ck-disk-full.md" \
  --severity P1 \
  --service clickhouse \
  --cluster mac-orbstack \
  --failure-class resource_exhaustion \
  --lesson "ClickHouse TTL purge silently fails if data directory ownership changes" \
  --tags "clickhouse,ttl,disk,permissions"

# List recent lessons
kyb lesson list --limit 10

# Search lessons
kyb lesson search --keyword "disk"

# Show failure class breakdown
kyb lesson stats --by failure-class
```

---

## 8. Post-Mortem ClickHouse Schema

### 8.1 Post-Mortem Metadata Table

```sql
CREATE TABLE infra.post_mortems (
    id              UUID DEFAULT generateUUIDv4(),
    created_at      DateTime DEFAULT now(),
    updated_at      DateTime DEFAULT now(),
    incident_date   Date,
    incident_id     String,
    file_path       String,               -- Path in docs/infra/postmortems/
    title           String,
    severity        LowCardinality(String),
    status          LowCardinality(String), -- Draft / Reviewed / Actions In Progress / Closed
    author          LowCardinality(String),
    reviewer        LowCardinality(String),

    -- Impact summary (denormalized for quick querying)
    duration_minutes      UInt32,
    users_affected        Nullable(UInt32),
    error_budget_consumed Nullable(Float32),
    data_loss             Bool DEFAULT false,
    mtta_minutes          Nullable(UInt32),
    mttr_minutes          Nullable(UInt32),

    -- Root cause summary
    direct_cause          String,
    failure_class         LowCardinality(String),

    -- Action item count
    action_item_count     UInt32 DEFAULT 0,
    action_item_closed    UInt32 DEFAULT 0,

    -- Timeline
    draft_deadline        Date,
    review_deadline       Date,
    draft_completed_at    Nullable(DateTime),
    review_completed_at   Nullable(DateTime),
    closed_at             Nullable(DateTime)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(incident_date)
ORDER BY (incident_date, severity, status)
TTL incident_date + INTERVAL 3 YEAR DELETE
```

### 8.2 Materialized Views

```sql
-- Monthly post-mortem summary
CREATE MATERIALIZED VIEW infra.post_mortems_monthly_mv
ENGINE = AggregatingMergeTree
ORDER BY (month, severity)
AS SELECT
    toStartOfMonth(incident_date) AS month,
    severity,
    count() AS total_pm,
    countIf(status = 'Closed') AS closed_pm,
    avg(duration_minutes) AS avg_duration,
    sum(error_budget_consumed) AS total_budget_consumed,
    sum(action_item_count) AS total_action_items,
    sum(action_item_closed) AS total_action_items_closed,
    countIf(data_loss = 1) AS data_loss_incidents
FROM infra.post_mortems
GROUP BY month, severity;

-- Action item aging view
CREATE MATERIALIZED VIEW infra.action_items_aging_mv
ENGINE = AggregatingMergeTree
ORDER BY (month, priority)
AS SELECT
    toStartOfMonth(deadline) AS month,
    priority,
    count() AS total_items,
    countIf(status = 'Open' OR status = 'In Progress') AS open_items,
    countIf(now() > deadline AND status != 'Closed' AND status != "Won't Do") AS overdue_items,
    avgIf(now() - deadline, now() > deadline AND status NOT IN ('Closed', "Won't Do")) AS avg_overdue_days
FROM infra.action_items
GROUP BY month, priority;
```

### 8.3 Action Items Table

```sql
CREATE TABLE infra.action_items (
    id              UUID DEFAULT generateUUIDv4(),
    created_at      DateTime DEFAULT now(),
    updated_at      DateTime DEFAULT now(),
    incident_id     String,               -- Links to post_mortems.incident_id
    postmortem_path String,

    ai_id           String,               -- AI-001, AI-002, ...
    description     String,
    type            LowCardinality(String), -- preventive / detective / process / systemic / mitigation / followup
    priority        LowCardinality(String), -- P0 / P1 / P2 / P3
    owner           LowCardinality(String),
    linked_issue    String,               -- GitLab issue URL
    deadline        Date,
    status          LowCardinality(String), -- Open / In Progress / Resolved / Verified / Closed / Won't Do
    verified_at     Nullable(DateTime),
    verified_by     Nullable(String),
    closed_at       Nullable(DateTime)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(deadline)
ORDER BY (deadline, priority, status)
TTL deadline + INTERVAL 2 YEAR DELETE
```

---

## 9. Grafana Dashboard

### 9.1 Post-Mortem Overview Dashboard

A single dashboard tracking post-mortem health:

**Panel 1: Post-Mortem Compliance**
- Gauge: % of mandatory post-mortems completed (draft submitted on time)
- Gauge: % of post-mortems reviewed (review completed)
- Goal: 100% for P0/P1, > 90% for P2 mandatory

**Panel 2: Action Item Closure Rate**
- Time series: cumulative action items created vs closed (rolling 30d)
- Stat: overall closure rate, average age of open items
- Table: oldest 10 open action items

**Panel 3: Failure Class Breakdown**
- Pie chart or bar chart: post-mortems grouped by failure class
- Allows identifying the most common failure patterns

**Panel 4: Incident Duration Trend**
- Time series: average incident duration by severity (rolling 30d)
- Overlay: are incidents getting shorter or longer over time?

**Panel 5: MTTA/MTTR Trend**
- Time series: average MTTA and MTTR by severity

**Panel 6: Repeat Offenders**
- Table: services with the most post-mortems in the last 90 days
- Highlight services with multiple incidents from same failure class

### 9.2 Layout

```
Row 1: [Post-Mortem Compliance] [Action Item Closure Rate]
Row 2: [Failure Class Breakdown] [Incident Duration Trend]
Row 3: [MTTA / MTTR Trend]       [Repeat Offenders]
```

---

## 10. Blameless Culture Rules

### 10.1 Language Guidelines

Post-mortems MUST avoid blame language:

| Avoid | Use Instead |
|-------|-------------|
| "Alice ran the wrong command" | "The command was run on the wrong instance because the hostname label was ambiguous" |
| "Bob deployed without testing" | "The deployment pipeline did not enforce test gating before production push" |
| "The engineer forgot to check" | "The check was manual and not surfaced in the deployment workflow" |
| "Someone fat-fingered the config" | "The config change had no review step or diff preview" |
| "Team should have known better" | "The relevant knowledge was tribal, not documented" |

### 10.2 Post-Mortem Review Checklist

Every post-mortem MUST pass these checks before being marked "Reviewed":

- [ ] No blame language (search for "who", "should have", "why did", "mistake")
- [ ] Root cause goes beyond the immediate trigger (at least 2 "whys")
- [ ] Action items are specific and verifiable (not "be more careful")
- [ ] Action items have owners and deadlines
- [ ] Failure class is assigned
- [ ] Lessons learned are written in a way that is useful to someone who wasn't there
- [ ] Timeline includes detection, mitigation, and resolution markers
- [ ] If there were no surprises, that is itself documented (what did you learn?)

### 10.3 Confidentiality

- Post-mortems are visible to the whole team (transparency)
- If the incident involves sensitive data (credentials, customer data), redact before saving
- Security incidents have a separate restricted section in the appendix
- Post-mortems are never used in performance reviews

---

## 11. Workflow Automation

### 11.1 Post-Mortem Creation Flow

```
Incident resolved (severity assessed)
    │
    ▼
Super-boss (or on-call) creates post-mortem issue
    │
    ▼
Issue template auto-populates from post-mortem template
    │
    ▼
Author writes post-mortem
    │
    ▼
Author creates MR with post-mortem file
    │
    ▼
Reviewer assigned (not the same person as author)
    │
    ▼
MR merged → webhook triggers:
  1. Entry added to infra.post_mortems
  2. Lessons entered into infra.lessons_learned
  3. Action item issues created in GitLab (if not already)
  4. Action items inserted into infra.action_items
  5. Feishu notification: new post-mortem published
```

### 11.2 Action Item Reminder Flow

```
Daily cron (or patrol task):
  1. Query infra.action_items WHERE status IN ('Open', 'In Progress') AND deadline < now() + 7d
  2. For items with deadline < 3d: Feishu DM to owner
  3. For items overdue: Feishu DM to owner + incident channel ping
  4. For items overdue > 14d: escalate to team lead
```

### 11.3 Weekly Review Automation

```
Every Monday:
  1. Generate summary of last week's incidents from infra.post_mortems
  2. List open action items with their ages
  3. Identify services with > 2 incidents in last 30d
  4. Post summary to Feishu incident-review channel
```

### 11.4 Monthly Report Automation

```
Every last Friday:
  1. Query last 30d from infra.post_mortems_monthly_mv
  2. Query action item closure rate from infra.action_items_aging_mv
  3. Query top 3 failure classes from infra.lessons_learned
  4. Generate monthly reliability report
  5. Post to Feishu + email to stakeholders
```

---

## 12. Related Documents

- `docs/infra/reviews/error-budget.md` -- Error budget tracking (incident cost in budget terms)
- `docs/infra/reviews/alert-fatigue.md` -- Alert fatigue monitoring (how alert noise affects incident detection)
- `docs/infra/observability-design.md` -- Overall observability architecture
- `docs/infra/5min-patrol-guide.md` -- Patrol system (automated anomaly detection)
