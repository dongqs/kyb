---
decision: 稍后做
---

# MR Cycle Time Tracking for Infra

> **Status:** Design Document
> **Date:** 2026-05-23
> **Context:** Measure and improve the infra team's MR throughput by tracking cycle time, review latency, and merge queue dynamics across all GitLab projects.

---

## Table of Contents

1. [Why Track MR Cycle Time](#1-why-track-mr-cycle-time)
2. [Cycle Time Stages](#2-cycle-time-stages)
3. [Metrics Definition](#3-metrics-definition)
4. [Data Source & Collection](#4-data-source--collection)
5. [ClickHouse Schema](#5-clickhouse-schema)
6. [Dashboard Design](#6-dashboard-design)
7. [Alerting](#7-alerting)
8. [Targets & SLOs](#8-targets--slos)
9. [Implementation Plan](#9-implementation-plan)
10. [Appendix: Manual Glab Commands](#10-appendix-manual-glab-commands)

---

## 1. Why Track MR Cycle Time

### 1.1 The Problem

Infra MRs sit in review for an unknown amount of time. There is no data on:

- How long does an MR take from open to merge?
- How long does the first review comment take to arrive?
- How many MRs are in the merge queue at any given time?
- Which projects have the worst review latency?
- Are we getting faster or slower over time?

Without data, every discussion about "review speed" is anecdote-driven.

### 1.2 What We Gain

| Benefit | Description |
|---------|-------------|
| Baseline | Know the current median/P90 cycle time per project |
| Trend | Track week-over-week and month-over-month changes |
| Bottleneck detection | Identify which stage (review / approval / merge) is slowest |
| Accountability | Visible metrics encourage faster reviews |
| Capacity planning | Queue length data tells us when the team is saturated |

### 1.3 Scope

| Included | Out of Scope |
|----------|-------------|
| All GitLab projects under `git.leyantech.com/infra/` | External MRs (OSS forks, upstream) |
| MRs created on or after tracking start date | Historical MR data (no backfill) |
| Cycle time, review latency, merge queue metrics | Code quality metrics (lines changed, file count) |
| Grafana dashboard + alerting | GitLab webhook integration (phase 2) |

---

## 2. Cycle Time Stages

An MR's life is broken into four stages:

```
Created  ──►  First Review  ──►  First Approval  ──►  Merged
  │                │                   │                   │
  │   wait_time    │   review_time     │   queue_time      │
  │◄──────────────►│◄─────────────────►│◄─────────────────►│
  │                                                         │
  │◄──────────────────── cycle_time ────────────────────────►│
```

### 2.1 Stage Definitions

| Stage | Start | End | What It Measures |
|-------|-------|-----|-----------------|
| **wait_time** | MR created_at | First non-author comment (human) | How long until someone looks at it |
| **review_time** | First non-author comment | First approval | How long the review cycle takes |
| **queue_time** | First approval | merged_at | How long it sits after approval (merge train, manual merge delay) |
| **cycle_time** | MR created_at | merged_at | Total end-to-end time |

### 2.2 Sub-Metrics per Stage

**wait_time:**
- Time to first human comment (any kind: question, suggestion, LGTM)
- Time to first reviewer assignment (if using CODEOWNERS or manual assign)

**review_time:**
- Number of review iterations (comment threads)
- Time between author push and reviewer response (ping-pong latency)
- Total number of unique reviewers

**queue_time:**
- Merge train length at time of enqueue
- Pipeline duration (if merge_when_pipeline_succeeds is used)
- Manual merge delay (approved but not yet merged)

---

## 3. Metrics Definition

### 3.1 Primary Metrics

Recorded per-MR and aggregated over time windows (1d, 7d, 30d):

| Metric | Unit | Aggregation | Definition |
|--------|------|-------------|------------|
| `cycle_time` | seconds | p50, p90, p99, avg, max | `merged_at - created_at` |
| `wait_time` | seconds | p50, p90, p99, avg | `first_review_at - created_at` |
| `review_time` | seconds | p50, p90, p99, avg | `first_approval_at - first_review_at` |
| `queue_time` | seconds | p50, p90, p99, avg | `merged_at - first_approval_at` |
| `review_depth` | count | p50, p90, max | Total non-author comments on the MR |
| `reviewers_count` | count | avg, max | Unique human reviewers who commented |

### 3.2 Queue Metrics

| Metric | Unit | Definition |
|--------|------|------------|
| `open_mrs` | count | Number of open MRs at any point in time |
| `queue_length` | count | Open MRs that have at least one approval (waiting for merge) |
| `stale_mrs` | count | Open MRs with no activity for >7 days |
| `merge_rate` | count/day | MRs merged per day (rolling 7d avg) |
| `throughput` | count/week | MRs merged per week |

### 3.3 Health Metrics

| Metric | Definition | What It Signals |
|--------|-----------|----------------|
| `revert_rate` | `reverted MRs / total merged MRs` (30d) | Quality issue: too many rushed merges |
| `no_review_merge_rate` | `MRs merged without any human comment / total merged MRs` (30d) | Process bypass: direct pushes or ignored review requirement |
| `stale_rate` | `stale_mrs / open_mrs` | Process bottleneck: nobody follows up |
| `review_workload` | `total_review_comments / unique_reviewers` (7d) | Individual reviewer burden |

---

## 4. Data Source & Collection

### 4.1 Architecture

```
GitLab API (git.leyantech.com)
    │
    ▼
Collection script (glab or curl)
    │   runs via cc-connect cron, every 5 minutes
    ▼
ClickHouse (mr.cycle_time)
    │
    ▼
Grafana (ClickHouse datasource)
```

### 4.2 Collection Script

A shell script `~/.kyb/bin/kyb-gl-mr-stats` polls GitLab for all infra projects and writes snapshot data to ClickHouse.

**Behavior:**

1. Every 5 minutes, query GitLab API for all open MRs in all infra projects.
2. For each open MR, record its current state (stage, elapsed times, labels, assignees).
3. Once per hour, also query recently merged MRs (past 1h) for final cycle time data.
4. Insert rows into ClickHouse table `mr.cycle_time` and `mr.cycle_time_final`.

**Why polling instead of webhooks:**

- No public HTTP endpoint needed (avoids a new deployment).
- `cc-connect cron` already exists and runs on the super-boss.
- Simpler to debug: data is as fresh as the poll interval, not dependent on webhook delivery.
- Webhook phase 2 can be added later for sub-minute granularity.

**Pseudo-code:**

```bash
#!/bin/bash
# kyb-gl-mr-stats -- collect MR cycle time data

INTERVAL=5m
PROJECTS=$(glab api "/groups/infra/projects" --paginate | jq -r '.[].path_with_namespace')

for PROJECT in $PROJECTS; do
  # Snapshot open MRs
  glab api "/projects/$PROJECT/merge_requests?state=opened&per_page=100" \
    | jq -c '.[]' \
    | while read -r MR; do
        compute_timings "$MR" | clickhouse-client --query "INSERT INTO mr.cycle_time FORMAT TabSeparated"
      done

  # Fetch recently merged MRs (final data)
  glab api "/projects/$PROJECT/merge_requests?state=merged&updated_after=$(date -d '-1 hour' -Iseconds)&per_page=100" \
    | jq -c '.[]' \
    | while read -r MR; do
        compute_final_timings "$MR" | clickhouse-client --query "INSERT INTO mr.cycle_time_final FORMAT TabSeparated"
      done
done
```

### 4.3 Field Extraction from GitLab API

GitLab MR API returns these relevant fields:

| API Field | Maps To | Notes |
|-----------|---------|-------|
| `iid` | mr_iid | Project-scoped MR number |
| `project_id` | project_id | GitLab project ID |
| `title` | title | Stored for reference |
| `author.id` | author_id | |
| `created_at` | created_at | ISO-8601 |
| `updated_at` | updated_at | ISO-8601 |
| `merged_at` | merged_at | null if not merged |
| `state` | state | opened/merged/closed |
| `merge_status` | merge_status | can_be_merged/checking/cannot_be_merged |
| `source_branch` | source_branch | |
| `target_branch` | target_branch | |
| `web_url` | web_url | Link to MR |
| `labels` | labels | Array of strings |
| `assignees[].id` | assignee_ids | Array |
| `reviewers[].id` | reviewer_ids | Array |
| `user_notes_count` | notes_count | Includes system notes; need to filter |
| `diff_stats` | changed_files, additions, deletions | Available via separate API endpoint |

**Notes (comments) must be fetched separately:**

```bash
glab api "/projects/$PROJECT/merge_requests/$IID/notes?per_page=100&sort=asc"
```

Each note has:
- `id`, `body`, `author.id`, `created_at`, `system` (boolean)
- Non-system notes with a non-author author = human review comments.
- The first such note after MR creation = `first_review_at`.
- The first approval event is recorded in the system notes with `body="approved this merge request"`.

**Approval state:**

```bash
glab api "/projects/$PROJECT/merge_requests/$IID/approval_state"
```

Returns which reviewers have approved. The first approval timestamp can be found by scanning system notes for "approved" events.

### 4.4 Data Freshness

| Data Type | Collection Interval | Max Lag |
|-----------|-------------------|---------|
| Open MR snapshot | 5 minutes | 5 minutes |
| Merged MR final record | 1 hour | 1 hour |
| Merge queue length | 5 minutes | 5 minutes |

---

## 5. ClickHouse Schema

### 5.1 Table: `mr.cycle_time` (Snapshots)

Records the state of each open MR at each poll interval. Used for queue length, wait time tracking, and time-series analysis.

```sql
CREATE TABLE mr.cycle_time (
  -- Primary key
  project_id    UInt64,
  mr_iid       UInt64,
  snapshot_at  DateTime,

  -- MR attributes
  title         String,
  author_id     UInt64,
  state         LowCardinality(String),  -- opened / merged / closed
  source_branch String,
  target_branch String,
  web_url       String,
  labels        Array(LowCardinality(String)),

  -- Timing fields (seconds since MR creation)
  age_seconds        UInt64,       -- snapshot_at - created_at
  has_human_comment  UInt8,        -- 1 if any non-author non-system comment exists
  has_approval       UInt8,        -- 1 if approved
  first_review_elapsed Nullable(UInt64),  -- seconds from created to first human comment (null if none)
  first_approval_elapsed Nullable(UInt64),

  -- Review depth
  human_comment_count UInt16,
  approval_count      UInt8,

  -- Size metadata (updated on snapshot)
  changed_files  UInt16,
  additions      UInt32,
  deletions      UInt32,

  -- Relationships
  assignee_ids   Array(UInt64),
  reviewer_ids   Array(UInt64)
)
ENGINE = ReplacingMergeTree
ORDER BY (project_id, mr_iid, snapshot_at)
TTL snapshot_at + TO_INTERVAL(90 DAY)
```

**Rationale:**
- `ReplacingMergeTree` allows upserting the latest snapshot for the same MR at the same time.
- 90-day TTL keeps history for trend analysis without unbounded storage.
- `LowCardinality` for `state` and `labels` since they repeat across many rows.

### 5.2 Table: `mr.cycle_time_final` (Completed MRs)

One row per merged MR with final computed metrics. Written once when the MR merges.

```sql
CREATE TABLE mr.cycle_time_final (
  project_id        UInt64,
  mr_iid           UInt64,
  merged_at        DateTime,
  created_at       DateTime,

  -- Core timing (seconds)
  cycle_time       UInt64,       -- merged_at - created_at
  wait_time        Nullable(UInt64),  -- first_review_at - created_at
  review_time      Nullable(UInt64),  -- first_approval_at - first_review_at
  queue_time       Nullable(UInt64),  -- merged_at - first_approval_at

  -- Quality
  human_comment_count UInt16,
  unique_reviewers    UInt16,
  additions           UInt32,
  deletions           UInt32,
  changed_files       UInt16,
  has_conflicts       UInt8,

  -- Labels at merge time
  labels           Array(LowCardinality(String)),

  -- Author
  author_id        UInt64
)
ENGINE = MergeTree
ORDER BY (project_id, merged_at)
TTL merged_at + TO_INTERVAL(365 DAY)
```

### 5.3 Table: `mr.cycle_time_daily` (Aggregated)

Pre-aggregated daily statistics for fast Grafana queries. Built by a nightly materialization.

```sql
CREATE TABLE mr.cycle_time_daily (
  date             Date,
  project_id       UInt64,
  project_name     String,

  -- Throughput
  merged_count     UInt32,
  opened_count     UInt32,
  closed_count     UInt32,

  -- Cycle time percentiles (seconds)
  cycle_time_p50   UInt32,
  cycle_time_p90   UInt32,
  cycle_time_p99   UInt32,

  -- Wait time
  wait_time_p50    Nullable(UInt32),
  wait_time_p90    Nullable(UInt32),

  -- Queue
  avg_queue_length Float64,      -- average open approved MRs during the day
  max_queue_length UInt32,

  -- Quality
  reverted_count   UInt8,
  no_review_merge_count UInt8,

  -- Size
  avg_additions    Float64,
  avg_deletions    Float64
)
ENGINE = SummingMergeTree
ORDER BY (date, project_id)
```

### 5.4 Materialization Schedule

| Table | Frequency | Method |
|-------|-----------|--------|
| `mr.cycle_time` | Every 5min | Insert from collection script |
| `mr.cycle_time_final` | Every 1h | Insert from collection script |
| `mr.cycle_time_daily` | Daily at 00:05 | `INSERT INTO ... SELECT` aggregation |

---

## 6. Dashboard Design

### 6.1 Dashboard: MR Cycle Time Overview

Single Grafana dashboard for at-a-glance infra MR health.

**Panel 1: Throughput (Stat)**
- MRs merged this week (count)
- MRs merged this month (count)
- Compared to previous period (green/red delta)

**Panel 2: Cycle Time Trend (Time Series)**
- X-axis: date
- Y-axis: median cycle time in hours
- Lines: p50, p90, p99
- Series: per-project or global
- Overlay: target line (e.g., 24h for p50)

**Panel 3: Cycle Time Breakdown (Stacked Bar)**
- One bar per MR (or per day)
- Stacked segments: wait_time, review_time, queue_time
- Reveals which stage dominates

**Panel 4: Merge Queue Length (Time Series)**
- X-axis: time (last 24h / 7d)
- Y-axis: count of open approved MRs
- Annotations: when MRs enter/leave the queue

**Panel 5: Review Latency Heatmap**
- X-axis: hour of day
- Y-axis: day of week
- Color: median wait_time for first review during that slot
- Reveals: are reviews faster on certain days/times?

**Panel 6: Stale MRs (Table)**
- Columns: Project, MR title, IID, Age (days), Last activity, Link
- Sorted by age descending
- Alert: any MR with age > 7 days

**Panel 7: Reviewer Workload (Bar Chart)**
- X-axis: reviewer name
- Y-axis: review comments left in the last 7 days
- Highlight individuals above threshold (e.g., > 50 comments/week)

**Panel 8: MR Size Distribution (Histogram)**
- X-axis: changed lines (log scale: 1-10, 10-100, 100-500, 500+)
- Y-axis: count of MRs
- Overlay: median cycle time per bucket
- Tests hypothesis: "larger MRs take longer to review"

### 6.2 Dashboard Variables

```yaml
variables:
  - name: project
    type: query
    query: SELECT DISTINCT project_name FROM mr.cycle_time_daily
    multi: true
    default: all

  - name: time_range
    type: interval
    values: [7d, 14d, 30d, 90d]
    default: 30d

  - name: author
    type: query
    query: SELECT DISTINCT author_id FROM mr.cycle_time_final
    multi: true
```

### 6.3 Sample Grafana Queries

**Query: Median cycle time per project (last 30d)**

```sql
SELECT
  project_name,
  quantile(0.5)(cycle_time) / 3600 AS p50_hours,
  quantile(0.9)(cycle_time) / 3600 AS p90_hours
FROM mr.cycle_time_daily
WHERE date > now() - INTERVAL 30 DAY
  AND merged_count > 0
GROUP BY project_name
ORDER BY p50_hours DESC
```

**Query: Merge queue length over time**

```sql
SELECT
  toStartOfHour(snapshot_at) AS hour,
  avg(age_seconds) / 3600 AS avg_age_hours,
  count() AS queue_length
FROM mr.cycle_time
WHERE snapshot_at > now() - INTERVAL 7 DAY
  AND has_approval = 1
  AND state = 'opened'
GROUP BY hour
ORDER BY hour
```

**Query: Stale MRs (open, no activity for 7+ days)**

```sql
SELECT
  project_id,
  mr_iid,
  title,
  age_seconds / 86400 AS age_days,
  web_url
FROM mr.cycle_time
WHERE snapshot_at = (SELECT max(snapshot_at) FROM mr.cycle_time)
  AND state = 'opened'
  AND age_seconds > 7 * 86400
ORDER BY age_days DESC
```

---

## 7. Alerting

### 7.1 Alert Rules

Evaluated by the patrol system (kyb-gl-issue-watch / cc-healthcheck / 5min patrol):

| Alert | Condition | Severity | Action |
|-------|-----------|----------|--------|
| **Stale MR** | Any MR open for > 14 days with no human comment | P3 | Ping author and last reviewer in Feishu |
| **Queue buildup** | Merge queue length > 5 for > 2 hours | P3 | Notify team lead; check if CI is broken or merge train is stuck |
| **No-review merge** | MR merged with 0 human comments | P3 | Flag for post-hoc review; tag in weekly report |
| **Throughput drop** | Weekly merged count drops > 50% vs previous 4-week average | P3 | Investigate: holidays? CI broken? Team overloaded? |
| **Revert spike** | > 1 revert in 24h | P2 | Bridge call to review merge process |

### 7.2 Notification Channels

| Severity | Channel | Frequency |
|----------|---------|-----------|
| P2 | Feishu group @oncall | Immediate |
| P3 | Daily report / Feishu group mention | Once per alert, no repeats within 24h |

### 7.3 Weekly Report (Auto-Generated)

Every Monday at 10:00, cc-connect cron generates a cycle time report:

```
=== MR Cycle Time Weekly Report (May 18-24, 2026) ===

Projects tracked: 8
Total MRs merged: 14
Reverts: 1 (7.1%)

Cycle times:
  Overall median: 4.2h
  Overall p90:    28.1h
  Slowest project: infra/cc-connect (median 12.7h)

Waiting for review (> 7d stale):
  - infra/proxy#23 "Update sing-box config" (12d)
  - infra/monitoring#8 "Add Kafka alerts" (9d)

Merge queue peak: 7 (Tue 14:30)
Review workload: kyb (24 comments), A1 (18), A2 (12)

Recommendations:
  1. Proxy#23 needs reviewer assignment -- assign @A2
  2. Merge queue spike on Tue correlates with broken CI -- fix CI before next release
```

---

## 8. Targets & SLOs

### 8.1 Initial Targets (30-day rolling)

Set empirically after 30 days of baseline data. Initial guesses:

| Metric | Target (p50) | Target (p90) | Notes |
|--------|-------------|-------------|-------|
| cycle_time | < 8h | < 48h | One working day for p50 |
| wait_time (first review) | < 2h | < 12h | Review within one work session |
| queue_time | < 1h | < 4h | Merge within half a day of approval |
| stale MRs | < 3 | < 5 | At any point in time |
| no_review_merge_rate | < 5% | -- | Quality gate |

### 8.2 Improvement Cycle

1. **Month 1:** Collect baseline. No targets, just observe.
2. **Month 2:** Set targets. Start weekly report.
3. **Month 3:** If not meeting targets, implement process changes:
   - Enforce reviewer assignment via CODEOWNERS
   - Set up merge train (GitLab Merge Trains feature)
   - Ban direct pushes to default branch
   - Implement WIP limits (max 3 open MRs per person)

### 8.3 Process Rules Derived from Metrics

| Condition | Rule |
|-----------|------|
| An MR has no reviewer after 4h | Patrol auto-assigns a reviewer round-robin |
| An MR has been approved but not merged after 2h | Patrol @mentions the author "this is approved, merge it" |
| A person has > 5 open MRs | Patrol warns "you have 5+ open MRs, finish some before opening more" |
| Merge queue > 8 | Patrol notifies team: "merge queue at 8, consider batch merge or CI priority" |

---

## 9. Implementation Plan

### Phase 1: Collection Pipeline (2 sessions)

| Step | Description | Deps |
|------|-------------|------|
| 1.1 | Create ClickHouse tables `mr.cycle_time` and `mr.cycle_time_final` | mig25 |
| 1.2 | Write `~/.kyb/bin/kyb-gl-mr-stats` collection script | glab credentials |
| 1.3 | Register cron job in cc-connect: every 5min snapshot, every 1h final | cc-connect cron |
| 1.4 | Validate: run script manually, check ClickHouse for data | -- |

### Phase 2: Dashboard & Alerts (2 sessions)

| Step | Description | Deps |
|------|-------------|------|
| 2.1 | Create Grafana dashboard with proposed panels | Phase 1 data |
| 2.2 | Write patrol check for stale MRs | cc-healthcheck |
| 2.3 | Write patrol check for merge queue buildup | cc-healthcheck |
| 2.4 | Set up weekly report cron job | Phase 1 data |

### Phase 3: Process Automation (2 sessions, optional)

| Step | Description | Deps |
|------|-------------|------|
| 3.1 | Auto-assign reviewers for unassigned MRs > 4h | GitLab API |
| 3.2 | Auto-merge approved MRs with passing CI | GitLab API |
| 3.3 | WIP limit enforcement | GitLab API |
| 3.4 | Merge train configuration | GitLab Premium? |

### Phase 2.5: Webhook Upgrade (optional)

If 5-minute polling granularity is insufficient:

- Configure GitLab project webhooks for `Merge Request Events`.
- Point webhooks at a lightweight HTTP endpoint (e.g., a tiny Go HTTP server or a Feishu-bridge extension).
- Webhook receiver inserts directly into `mr.cycle_time`.
- Benefits: sub-second granularity, no polling overhead.
- Cost: requires a public-facing or VPN-accessible HTTP endpoint.

---

## 10. Appendix: Manual Glab Commands

For ad-hoc queries during development:

```bash
# List all infra projects
glab api "/groups/infra/projects?per_page=100" | jq -r '.[].path_with_namespace'

# List open MRs for a project
glab api "/projects/infra%2Fcc-connect/merge_requests?state=opened" | jq -r '.[].title'

# Get MR details with timestamps
glab api "/projects/infra%2Fcc-connect/merge_requests/42" | jq '{iid, title, created_at, merged_at, state}'

# Get MR notes (comments)
glab api "/projects/infra%2Fcc-connect/merge_requests/42/notes?per_page=100&sort=asc" | jq '.[] | {id, author, system, created_at, body}'

# Get approval state
glab api "/projects/infra%2Fcc-connect/merge_requests/42/approval_state"

# Get diff stats
glab api "/projects/infra%2Fcc-connect/merge_requests/42" | jq '{changes_count, diff_refs}'
```
