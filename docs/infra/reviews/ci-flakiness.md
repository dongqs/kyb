---
decision: 稍后做
---

# CI Pipeline Flakiness Tracking

**Author:** Boss
**Status:** Draft
**PR:** TBD

## 1. Problem Statement

CI pipeline reliability is a leading indicator of engineering velocity. When pipelines fail intermittently due to infrastructure or test flakiness (not legitimate code bugs), developers lose trust in CI, merge slower, and waste time re-running pipelines.

Analysis of the last 100 pipelines on the kyb project reveals:

| Metric | Value |
|--------|-------|
| Overall failure rate (all pipelines) | ~25% |
| Master branch failure rate | 24% (4/17) |
| MR failure rate | 23% (19/83) |
| Infrastructure failure rate (`runner_system_failure`) | ~4% |
| Pipeline cancellation rate (MR #142) | 28% (12/43) |

Master failing 24% of the time is unacceptable. Master should be the gold standard of passing code. Each master failure represents either a merge of broken code or an infrastructure flake that blocked the pipeline retroactively.

Cancellation rate is also a red flag -- 28% of MR #142's pipelines were canceled. Cancelled pipelines represent either duplicate retries or deliberately aborted runs, both of which waste runner resources and slow feedback loops.

### 1.1 Scope

| Included | Not included |
|----------|-------------|
| Pipeline pass/fail rate per ref and branch | Developer productivity metrics |
| Job-level failure classification (`script_failure` vs `runner_system_failure`) | Code coverage tracking |
| Flaky test detection (same test passes/fails on retry) | Test execution time optimization |
| Retry/rerun frequency per pipeline | Runner provisioning and capacity planning |
| Master branch regression monitoring | Merge queue performance |

## 2. Core Metrics

### 2.1 Pipeline Pass Rate

Track pass/fail rate over time, segmented by branch type and failure category.

**Metric: `ci.pipeline.status`**

| Label | Type | Values |
|-------|------|--------|
| `project` | string | `kyb` |
| `ref` | string | Branch or tag name |
| `ref_type` | string | `master` / `mr` / `tag` |
| `source` | string | `push` / `merge_request_event` / `web` / `schedule` |
| `status` | string | `success` / `failed` / `canceled` |
| `failure_category` | string | See below |

**Failure categories:**

| Category | GitLab failure_reason | Meaning |
|----------|----------------------|---------|
| `infrastructure` | `runner_system_failure`, `runner_unsupported`, `stuck_or_timeout_critical_job`, `environment_creation_failure` | Runner or CI infra issue |
| `script_failure` | `script_failure` | Test exited non-zero |
| `config` | `job_definition_mismatch` | CI YAML is broken |
| `api_failure` | `api_failure` | GitLab API called during job failed |
| `unknown` | (blank or unmapped) | Needs manual classification |

**Source (ClickHouse):**

```sql
CREATE TABLE infra.ci_pipelines (
    timestamp          DateTime64(3)       CODEC(ZSTD(3)),
    pipeline_id        UInt64,
    project            LowCardinality(String),
    ref                String,
    ref_type           LowCardinality(String),
    source             LowCardinality(String),
    status             LowCardinality(String),
    failure_reason     LowCardinality(String),
    failure_category   LowCardinality(String),
    duration_seconds   Float64,
    created_at         DateTime64(3),
    finished_at        Nullable(DateTime64(3)),
    git_sha            String,

    -- Job-level breakdown (denormalized for simplicity)
    total_jobs         UInt8,
    failed_jobs        UInt8,

    -- MR context (null for non-MR pipelines)
    mr_iid             Nullable(UInt32),
    mr_author          Nullable(String)
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, project, status)
TTL timestamp + INTERVAL 365 DAY DELETE
```

**Derived: `ci.pass_rate`**

Rolling pass rate over time windows.

```sql
-- Daily pass rate
CREATE MATERIALIZED VIEW infra.ci_pass_rate_daily_mv
ENGINE = AggregatingMergeTree
ORDER BY (date, project, ref_type)
AS SELECT
    toDate(timestamp) AS date,
    project,
    ref_type,
    source,
    count() AS total_pipelines,
    countIf(status = 'success') AS passed,
    countIf(status = 'failed') AS failed,
    countIf(status = 'canceled') AS canceled,
    countIf(failure_category = 'infrastructure') AS infra_failures,
    countIf(failure_category = 'script_failure') AS script_failures,
    -- Pass rate excluding infra failures (shows true code quality)
    countIf(status = 'success') / countIf(status IN ('success', 'failed') AND failure_category != 'infrastructure') AS code_pass_rate
FROM infra.ci_pipelines
GROUP BY date, project, ref_type, source;
```

### 2.2 Rerun / Retry Frequency

Track how many pipelines are retried per ref. High retry count on the same ref signals either flaky tests or developer chasing a green pipeline.

**Metric: `ci.pipeline.retry_count`**

| Label | Type | Values |
|-------|------|--------|
| `ref` | string | Branch |
| `pipeline_count` | int | Number of pipelines triggered for this ref |
| `retry_count` | int | Pipelines after the first, on the same ref |
| `retry_reason` | string | `auto_retry` / `manual_retry` |

**Flakiness Score per Ref:**

```
flakiness_score = (pipelines_before_first_success - 1) + (total_failures_on_ref)

where:
  pipelines_before_first_success = number of consecutive non-success pipelines before the first green
  total_failures_on_ref          = total failed pipelines for this git ref + MR combination
```

A `flakiness_score` > 2 warrants investigation. The ideal is 0 (first pipeline passed green).

### 2.3 Job-Level Failure Tracking

The pipeline-level view is the starting point, but jobs are where the diagnosis happens. Each job within a pipeline carries a status and failure reason.

**Metric: `ci.job.status`**

| Label | Type | Values |
|-------|------|--------|
| `pipeline_id` | UInt64 | Parent pipeline |
| `job_id` | UInt64 | GitLab job ID |
| `job_name` | string | `test` |
| `status` | string | `success` / `failed` / `canceled` |
| `failure_reason` | string | GitLab failure reason |
| `runner` | string | Runner hostname |
| `duration` | Float64 | Job execution time (seconds) |

**Flaky Job Detection:**

A job is flagged as potentially flaky when:

1. Same `job_name` fails on one pipeline run and passes on the **immediately following** retry, with **no code change** between runs (same git SHA).
2. Same `job_name` fails on the same `ref` intermittently across multiple pipeline runs with `failure_reason = runner_system_failure` (infrastructure, not code).

**Source table:**

```sql
CREATE TABLE infra.ci_jobs (
    timestamp          DateTime64(3)       CODEC(ZSTD(3)),
    pipeline_id        UInt64,
    job_id             UInt64,
    job_name           LowCardinality(String),
    stage              LowCardinality(String),
    status             LowCardinality(String),
    failure_reason     LowCardinality(String),
    failure_category   LowCardinality(String),
    runner             LowCardinality(String),
    duration_seconds   Float64,
    created_at         DateTime64(3),
    started_at         Nullable(DateTime64(3)),
    finished_at        Nullable(DateTime64(3)),

    -- Link back to pipeline context
    ref                String,
    ref_type           LowCardinality(String),
    source             LowCardinality(String),
    git_sha            String,
    mr_iid             Nullable(UInt32),

    -- Dedup key
    job_retry_count    UInt8
)
ENGINE = ReplicatedMergeTree
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, job_name, status)
TTL timestamp + INTERVAL 90 DAY DELETE
```

### 2.4 Master Regression Index

Master failures are the most expensive type of CI failure. A master pipeline failure means either:

1. Code merged to master was broken (gate failure)
2. Infrastructure flaked after merge (random failure)

**Metric: `ci.master_regression`**

```
master_regression_count = count of failed pipelines on master ref in rolling 7d window
```

| Level | Failures/7d | Action |
|-------|-------------|--------|
| Green | 0-1 | Healthy |
| Yellow | 2-3 | Investigate patterns, check if same runner |
| Red | 4+ | Pause merges until root cause identified |

Current baseline: **4 failures in ~17 pipelines** on master (24%). Red.

### 2.5 Composite Flakiness Index (CFI)

Single score summarizing CI flakiness health.

```
CFI = (master_failure_rate * 0.4) + (infra_failure_rate * 0.3) + (retry_excess_rate * 0.3)

where:
  master_failure_rate = failed_master_pipelines / total_master_pipelines (rolling 7d)
  infra_failure_rate  = infra_failures / total_failures (rolling 7d)
  retry_excess_rate   = max(0, (avg_retries_per_ref - 1) / 5)  -- normalized, capped at 1.0
```

| Score | Status | Color |
|-------|--------|-------|
| 0 - 0.1 | Healthy | Green |
| 0.1 - 0.3 | Deteriorating | Yellow |
| 0.3 - 0.6 | Flaky | Orange |
| > 0.6 | Critical | Red |

## 3. Data Collection

### 3.1 GitLab API Polling

A lightweight collector script runs on a schedule and polls the GitLab CI API for pipeline and job data.

**Collection script design (`~/.kyb/bin/kyb-ci-flakiness-collect`):**

```bash
#!/bin/bash
# CI Flakiness data collector
# Fetches recent pipelines + jobs from GitLab and writes to ClickHouse.
# Intended to run every 5 minutes via cc-connect cron.

set -euo pipefail

PROJECT="quick-n-dirty/kyb"
CK_TABLE_PIPELINES="infra.ci_pipelines"
CK_TABLE_JOBS="infra.ci_jobs"

# Get pipelines updated in the last 10 minutes (buffer for late-arriving data)
SINCE=$(date -d '10 minutes ago' --iso-8601=seconds)
PIPELINES=$(glab api "projects/${PROJECT}/pipelines?updated_after=${SINCE}&per_page=100")

# Process and write pipelines
echo "$PIPELINES" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data:
    ref = p['ref']
    ref_type = 'master' if ref == 'master' else ('mr' if ref.startswith('refs/') else 'branch')
    mr_iid = None
    mr_author = None
    if ref.startswith('refs/merge-requests/') and 'merge_request_event' in p.get('source', ''):
        # Parse MR IID from ref
        parts = ref.split('/')
        if len(parts) >= 4:
            mr_iid = int(parts[3])

    print(json.dumps({
        'timestamp': p.get('created_at'),
        'pipeline_id': p['id'],
        'project': '$PROJECT',
        'ref': ref,
        'ref_type': ref_type,
        'source': p.get('source', ''),
        'status': p['status'],
        'failure_reason': detect_failure_reason(p['id']),
        'failure_category': classify_failure(detect_failure_reason(p['id'])),
        'duration_seconds': p.get('duration'),
        'created_at': p.get('created_at'),
        'finished_at': p.get('finished_at'),
        'git_sha': p.get('sha'),
        'mr_iid': mr_iid,
        'mr_author': mr_author,
    }))
"
```

**Failure reason detection:**

```python
def detect_failure_reason(pipeline_id):
    """Fetch the first failed job and return its failure_reason."""
    jobs = glab_api(f"projects/{PROJECT}/pipelines/{pipeline_id}/jobs?per_page=50")
    for j in jobs:
        if j['status'] == 'failed' and j.get('failure_reason'):
            return j['failure_reason']
    return ''

def classify_failure(reason):
    if reason in ('runner_system_failure', 'runner_unsupported', 'stuck_or_timeout_critical_job', 'environment_creation_failure'):
        return 'infrastructure'
    if reason == 'script_failure':
        return 'script_failure'
    if reason == 'api_failure':
        return 'api_failure'
    return 'unknown'
```

### 3.2 Collector Deployment

The collector runs on the kyb-infra host (or any host with `glab` CLI access and ClickHouse client).

**Schedule: every 5 minutes.**

```bash
# Add via cc-connect cron
cc-connect cron add --name ci-flakiness-collect \
  --schedule "*/5 * * * *" \
  --exec "~/.kyb/bin/kyb-ci-flakiness-collect >> ~/.kyb/logs/ci-flakiness-collect.log 2>&1"
```

### 3.3 Data Retention

| Table | Retention | Rationale |
|-------|-----------|-----------|
| `infra.ci_pipelines` | 365 days | Year-over-year comparison |
| `infra.ci_jobs` | 90 days | Job-level data is high volume; older jobs rarely analyzed |

## 4. Dashboard

### 4.1 Grafana Dashboard: CI Flakiness

A single dashboard with three rows:

**Row 1: Pipeline Overview**
- Time series: pipeline pass rate by ref_type (master vs MR) over time
- Stat panel: current pass rate (24h), CFI score, master regression count (7d)
- Stat panel: total pipelines (24h), total failures by category
- Table: Top-5 flakiest refs by flakiness_score (7d)

**Row 2: Failure Breakdown**
- Stacked bar: failure count by category (infrastructure, script, config) per day
- Pie chart: failure category distribution (7d)
- Time series: `runner_system_failure` rate over time (identify runner health degradation)
- Table: Most common failure reasons (7d)

**Row 3: Rerun / Retry Analysis**
- Histogram: retry count distribution per ref
- Time series: total pipelines triggered per hour (detects CI spam from auto-retry loops)
- Stat panel: average retries per ref (7d)
- Table: Refs with > 3 retries (needs attention)

### 4.2 Alert Rules

| Rule | Expression | Severity | Description |
|------|-----------|----------|-------------|
| MasterPipelineFailed | `count(ci_pipeline_status{ref="master", status="failed"}[1h]) > 0` | P1 | A master pipeline failed in the last hour |
| HighFlakinessIndex | `ci_flakiness_index > 0.3` | P2 | CFI elevated, investigate flaky tests or infra |
| HighMasterFailRate | `(count(ci_pipeline_status{ref="master", status="failed"}[7d]) / count(ci_pipeline_status{ref="master"}[7d])) > 0.1` | P1 | Master fail rate exceeds 10% over 7 days |
| InfraFailureSpike | `rate(ci_pipeline_status{failure_category="infrastructure"}[1h]) / rate(ci_pipeline_status{failure_category="infrastructure"}[1d]) > 3` | P2 | Spike in infrastructure failures |
| RunnerDown | `count(ci_job_status{runner="gitlab-runner-k8s-dev", status="failed", failure_reason="runner_system_failure"}[30m]) > 3` | P1 | Runner keeps failing jobs |
| ExcessiveRetries | `max(ci_pipeline_retry_count[1d]) > 5` | P2 | A single ref triggered > 5 pipelines in a day (possible retry spam) |

## 5. Investigation Workflow

### 5.1 When a Master Pipeline Fails

```
1. Alert fires "MasterPipelineFailed"
2. Check the specific pipeline in GitLab UI
3. Identify failure_reason:
   a. runner_system_failure → tag the pipeline in ClickHouse with category infrastructure
      → Check runner health (is runner gitlab-runner-k8s-dev online?)
      → Retry the pipeline if runner was the issue
   b. script_failure → Check if this is a real code regression:
      i.   git diff between the failing SHA and the last passing SHA on master
      ii.  If diff is empty or unrelated → flaky test. Tag and file issue.
      iii. If diff contains the broken code → rollback immediately (P0)
```

### 5.2 Flaky Test Investigation

When the same test file passes on one run and fails on another with no code change:

1. Label the pipeline pair in `infra.ci_jobs` with `is_flaky = true`
2. Link to a GitLab issue in the `kyb` project with label `flaky-test`
3. Run the test locally 10 times to reproduce: `ruby -Itest test/test_check.rb`
4. If reproducible: fix the test (race condition, timing, external dependency)
5. If not reproducible: tag with `quarantine` and increase retry count in CI config

### 5.3 Runner Infrastructure Diagnosis

If `runner_system_failure` appears across multiple pipelines and projects:

1. Check runner status: `glab runner list`
2. Check runner logs on the K8s cluster
3. Common causes:
   - Image pull failure (registry proxy down)
   - Pod OOMKilled
   - Node resource pressure (CPU/memory)
   - Network timeout (proxy issue for SOCKS5)

### 5.4 Weekly CI Health Review

Every Monday, review CI Flakiness dashboard and:

1. **Master failures this week** -- categorize each as code regression vs infrastructure
2. **Top 5 flakiest refs** -- who is retrying the most, and why?
3. **Infrastructure failure trend** -- is the runner getting worse?
4. **CFI score trend** -- is it improving or degrading?

Actions are tracked as issues with label `ci-flakiness`.

## 6. Implementation Phases

### Phase 1: Data Collection (Week 1)

- [ ] Create ClickHouse tables: `infra.ci_pipelines`, `infra.ci_jobs`
- [ ] Write collector script: `kyb-ci-flakiness-collect` (bash + python3 wrapper for glab API)
- [ ] Deploy via cc-connect cron, every 5 minutes
- [ ] Validate: data appears in ClickHouse within 5 minutes of pipeline completion
- [ ] Basic Grafana dashboard: pipeline pass rate over time

### Phase 2: Flaky Detection (Week 2)

- [ ] Implement flaky job detection: compare consecutive pipelines with same SHA
- [ ] Add `is_flaky` flag to `infra.ci_jobs` via post-processing step in collector
- [ ] Compute flakiness_score per ref
- [ ] Add alerts: HighFlakinessIndex, MasterPipelineFailed
- [ ] Enhance dashboard: failure breakdown, retry analysis

### Phase 3: Automation (Week 3)

- [ ] Auto-create GitLab issues for detected flaky tests
- [ ] Auto-quarantine: flaky tests > 3 days old auto-excluded from CI run
- [ ] Weekly CI health review template (Feishu doc)
- [ ] Runner health probe: check runner status before pipeline trigger

### Phase 4: Culture & Gates (Week 4)

- [ ] Enforce master pass rate gate: if master fail rate > 10% in 24h, block new merges
- [ ] Add CI reliability to team dashboard
- [ ] Require flaky test issues for any test that fails intermittently
- [ ] Document in onboarding: how to classify CI failures

## 7. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Collector fails silently | Medium | Medium | Add heartbeat metric; alert if no data in 30 minutes |
| GitLab API rate limiting | Low | Medium | Cache responses; batch writes; paginate carefully |
| False flaky detection (same SHA different code via merge commit) | Medium | Low | MD5 of CI script output as secondary dedup signal |
| Table grows too large | Low | Low | 365d TTL on pipelines, 90d on jobs. ~100 pipelines/day = trivial volume |
| Not classifying failures correctly | Medium | High | Default category = `unknown`; manual re-classification via CLI |
| Developers ignore the dashboard | Medium | Medium | Alert on master failure is the trigger; dashboard is for weekly review only |

## 8. Future Considerations

### 8.1 Retry Budget per MR

Introduce a "retry budget" -- limit automated pipeline retries to 3 per SHA before requiring manual confirmation. This prevents CI spam when tests are persistently failing.

Implementation: GitLab CI `retry:max: 3` in job config + webhook that alerts when a pipeline is retried > 3 times.

### 8.2 Merge Queue Integration

If GitLab Merge Trains are enabled, track merge queue entry/exit as CI events. A pipeline that fails after entering the merge queue is a higher-severity event.

### 8.3 Cross-Project Flakiness

As the kyb infra org grows to multiple projects, aggregate CI flakiness across all projects into a single dashboard. This helps distinguish between:
- **Project-level flakiness** (bad tests in one project) vs
- **Platform-level flakiness** (runner issues affecting all projects)

### 8.4 Predictive Flakiness

Train a simple model on historical data: "given this test file, this runner, this time of day, probability of failure = X%". Alert on significant deviation from expected probability.

## 9. Success Criteria

| Criterion | Current | Target (30 days) | Target (90 days) |
|-----------|---------|-------------------|--------------------|
| Master pass rate | 76% (24% failure) | > 90% | > 95% |
| MR pass rate | 77% | > 85% | > 90% |
| Infrastructure failure rate | ~4% | < 2% | < 1% |
| Average retries per ref | > 2 (estimated) | < 2 | < 1.5 |
| CFI score | > 0.3 (estimated) | < 0.2 | < 0.1 |
| Time to detect master failure | Manual | < 5 min | < 2 min |

## 10. Related Documents

- `docs/infra/reviews/alert-fatigue.md` -- alert meta-monitoring (shared infrastructure patterns)
- `docs/infra/observability-design.md` -- overall observability architecture
- `.gitlab-ci.yml` -- CI configuration for kyb project
