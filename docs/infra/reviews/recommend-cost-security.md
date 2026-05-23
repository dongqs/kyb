---
decision: 稍后做
---

# Recommendations: Cost Tracking and Security Monitoring

**Date:** 2026-05-23
**Status:** Synthesis / Prioritized Action Plan
**Source designs:**
- `docs/infra/reviews/token-cost.md` -- LLM token spend tracking
- `docs/infra/reviews/cost-per-service.md` -- Container resource cost allocation
- `docs/infra/reviews/secret-rotation.md` -- Credential rotation monitoring
- `docs/infra/reviews/vuln-scan.md` -- Container image vulnerability scanning
- `docs/infra/reviews/token-efficiency.md` -- Per-tool and per-decision token burn

---

## Table of Contents

1. [Priority Matrix](#1-priority-matrix)
2. [Cost Tracking Recommendations](#2-cost-tracking-recommendations)
3. [Security Monitoring Recommendations](#3-security-monitoring-recommendations)
4. [Phased Implementation Plan](#4-phased-implementation-plan)
5. [What NOT to Do (Yet)](#5-what-not-to-do-yet)
6. [Alert Fatigue Risk Assessment](#6-alert-fatigue-risk-assessment)
7. [Quick-Start Commands](#7-quick-start-commands)

---

## 1. Priority Matrix

Each initiative is ranked by **impact** (cost saved or risk reduced) vs **effort** (hours to initial value).

| Initiative | Impact | Effort | Priority | Why |
|-----------|--------|--------|----------|-----|
| **Token cost tracking** | High | 2h | P0 | LLM API bills are the #1 variable cost. No visibility today. Every agent session burns real money. |
| **Vulnerability scanning** | High | 4h | P0 | 30+ container images, many on `latest` tag, zero scanning. A Log4j-class CVE in production is undetectable today. |
| **Secret rotation monitoring** | Medium | 2h | P1 | No credential expiry tracking = silent outages when tokens expire. But most infra secrets are long-lived and stable. |
| **Infra cost per service** | Low | 6h | P2 | ~$93/mo total infra cost. Insight is useful but the absolute spend is too low to justify early effort. The real value is capacity planning, not cost savings. |
| **Token efficiency** | Medium | 6h | P1 | After basic cost tracking is live, efficiency optimization yields 2-10x cost reduction per session. High ROI but depends on token cost data being in place first. |

**Bottom line:** Do token cost tracking and vulnerability scanning first (today). Add secret rotation monitoring next (this week). Defer infra cost allocation and token efficiency until Phase 2.

---

## 2. Cost Tracking Recommendations

### 2.1 Token Cost Tracking (P0 -- Do Today)

**Design:** `token-cost.md`

This is the highest-ROI monitoring initiative in the entire infra stack. LLM API costs are the dominant variable expense of the kyb system, and currently there is zero visibility.

**What to build:**

| Step | Action | Time | Dependencies |
|------|--------|------|-------------|
| 1 | Create ClickHouse tables: `infra.token_usage`, `infra.token_usage_daily`, `infra.token_budgets`, `infra.model_pricing` | 5 min | CK access |
| 2 | Seed `infra.model_pricing` with current model rates | 5 min | -- |
| 3 | Deploy `token-tracker.sh` on boss container (Mode B from design) | 30 min | Boss access |
| 4 | Verify data flowing in CK with test queries | 10 min | -- |
| 5 | Build 8-panel Grafana dashboard | 1h | Grafana access |
| 6 | Add budget alert queries to patrol cycle | 30 min | Patrol integration |

**Key design decisions to follow:**

- Use **Mode B** first (boss log tail, no sandbox changes) for speed. Mode A (in-sandbox daemon) can be added later for higher accuracy.
- Use **end-of-turn token summaries** from Claude Code stdout -- no API dependency, works with any LLM provider.
- Cache read/write tracking is essential for prompt caching ROI analysis. Include it from day 1.
- Token counts are metadata only (no prompt content). Privacy-safe.

**Budget recommendations:**

| Project | Daily Budget | Monthly Budget | Alert At |
|---------|-------------|---------------|----------|
| kyb (infra) | $3.00 | $90 | 80% |
| All projects total | $10.00 | $300 | 80% |

Start conservative. Adjust after 2 weeks of data.

**Alert rules to enable immediately:**

| Condition | Severity | Action |
|-----------|----------|--------|
| Single session cost > $10 | P3 | Feishu: investigate session |
| Project daily budget > 80% | P3 | Feishu warning |
| Project daily budget exceeded | P2 | Feishu alert |
| Cost anomaly (today > 3x trailing 7d avg) | P2 | Feishu alert |
| Agent > 50% of project daily budget | P2 | Feishu: agent may be stuck in loop |

### 2.2 Infra Cost Per Service (P2 -- Defer)

**Design:** `cost-per-service.md`

**Why defer:** At ~$93/mo total infra cost, even a 50% overrun is $46/mo -- less than a single hour of LLM API calls. The effort to set up and maintain resource collection (~6h) does not pay back.

**When to revisit:**

- Infrastructure expands to 3+ clusters with 50+ containers
- Cloud VM costs exceed $200/mo
- A service needs capacity planning justification (e.g., "should we run ClickHouse on a dedicated machine?")

**What to keep from the design:**

- The allocation formula (50% equal split + 50% memory-proportional) is sound and simple.
- The ClickHouse schema is well-designed. Deploy it when needed.
- The insight about **boss container sprawl** (4 boss containers = 26% of cluster cost) is actionable now even without automated collection: prune to 1-2 boss containers.

### 2.3 Token Efficiency (P1 -- After Token Cost Tracking Is Live)

**Design:** `token-efficiency.md`

**Why not P0:** Requires token cost tracking data to be flowing first. Efficiency is meaningless without a baseline.

**What to prioritize when starting:**

1. Identify the most token-expensive tools (which tool calls cost the most per invocation)
2. Measure dispatch loop overhead (what % of tokens go to boss coordination vs actual work)
3. Set efficiency SLOs: e.g., "no single tool call should exceed 5,000 output tokens"
4. Add prompt caching effectiveness dashboard panel (cache hit rate from `infra.token_usage`)

---

## 3. Security Monitoring Recommendations

### 3.1 Vulnerability Scanning (P0 -- Do Today)

**Design:** `vuln-scan.md`

The kyb infra runs 30+ container images, many on `latest` tags with zero pinning, and none are scanned for CVEs. This is the biggest security gap.

**What to build:**

| Step | Action | Time | Dependencies |
|------|--------|------|-------------|
| 1 | Deploy Trivy as a Docker container on mac-orbstack | 15 min | Docker |
| 2 | Create `infra/images.txt` with all current image:tag:digest entries | 15 min | Running containers |
| 3 | Run first manual scan of all images | 10 min | -- |
| 4 | Create ClickHouse tables: `image_vulnerabilities`, `image_scan_summary`, `image_fix_age` | 10 min | CK access |
| 5 | Write Ruby scan parser (`infra/vuln/parse-scan.rb`) | 1h | -- |
| 6 | Create `infra/vuln/ignored-cves.json` with initial false positives | 15 min | Scan results |
| 7 | Add daily scan cron to boss container | 30 min | Boss access |
| 8 | Build Grafana dashboard (8 panels from design) | 1.5h | Grafana access |

**Immediate scan findings to expect (from design doc):**

- `confluentinc/cp-kafka:latest` -- high risk, no pin
- `grafana/grafana:latest` -- high risk, no pin
- `prometheuscommunity/postgres-exporter:latest` -- high risk, no pin
- `oliver006/redis_exporter:latest` -- high risk, no pin
- `danielqsj/kafka-exporter:latest` -- high risk, no pin
- `prom/node-exporter:latest` -- high risk, no pin
- `postgres:16` -- medium risk, minor tag drifts

**Critical: Pin all `latest` tags to specific versions or digests after the first scan.** Do not wait for Phase 2 on this.

**Alert rules to enable immediately:**

| Condition | Severity | Action |
|-----------|----------|--------|
| Critical CVE in production image (non-sandbox) | P1 | Feishu alert + create remediation issue |
| Fix age > 72h for fixable critical CVE | P2 | Feishu alert |
| New critical CVE detected in sandbox build | P2 | Feishu alert |
| Any image not scanned in 48h | P3 | Feishu: check cron/boss health |
| Scanner DB older than 48h | P3 | Feishu: refresh DB |

**What NOT to build initially (from the full design):**

- CI gates that block builds (add in Phase 2 after baseline is established)
- Fix age algorithm (add in Phase 2 after 2+ scans per image exist)
- `kyb vuln` CLI subcommands (nice-to-have, not essential)

### 3.2 Secret Rotation Monitoring (P1 -- This Week)

**Design:** `secret-rotation.md`

**Why P1 not P0:** No secret has actually expired and caused an outage recently. Vulnerability scanning has higher immediate risk (unpatched CVEs are more likely to be exploited than an expired Feishu token). However, the effort is low (~2h to initial value) and a single expired secret can block the entire CI/CD pipeline.

**What to build (minimal viable version):**

| Step | Action | Time |
|------|--------|------|
| 1 | Create `~/.kyb/secrets/registry.yml` with 5-10 critical secrets | 30 min |
| 2 | Write `secret-rotation-check` patrol script | 30 min |
| 3 | Add rotation check to 5-min patrol | 15 min |
| 4 | Set up Feishu alert for overdue secrets | 15 min |

**Minimal scope (Phase 1):**

Start with only these secret categories:

| Secret | Policy | Why Track |
|--------|--------|-----------|
| Feishu app token | 90 days | Active, production-critical. Rotation is manual. |
| TLS certs (Let's Encrypt) | 90 days | Auto-renewed but monitoring catches renewal failures early. |
| GitLab deploy tokens / PATs | 180 days | CI/CD blocker if expired. |
| PostgreSQL passwords | 180 days | Compliance. Low in practice (local trust auth). |
| OpenAI / Anthropic API keys | 90 days | Direct cost impact if rotated breaks agents. |

**Defer:**

- SSH keys (rotate once/year, low urgency)
- Cloud provider keys (only 1-2 keys, known state)
- Service-to-service tokens (not yet deployed)

**Alert rules to enable immediately:**

| Condition | Severity | Action |
|-----------|----------|--------|
| Secret past rotation policy | P0 | Feishu @all + TTS notify |
| TLS certificate expired | P0 | Feishu @all + TTS notify |
| Secret > 90% of policy | P1 | Feishu group |
| Cert < 14 days to expiry | P1 | Feishu group |

---

## 4. Phased Implementation Plan

### Phase 0: Today (4h total)

```
Hour 0-1: Token cost tracking
  - Create CK tables
  - Seed model pricing
  - Deploy token-tracker.sh on boss (Mode B)

Hour 1-2: Vulnerability scanning
  - Deploy Trivy container
  - Create infra/images.txt
  - Run first manual scan of all images

Hour 2-3: Vulnerability scanning (continued)
  - Create CK tables
  - Write scan parser
  - Create ignored-cves.json

Hour 3-4: Token cost continued
  - Verify data flowing in CK
  - Build Grafana dashboard (basic version: daily cost, top sessions, budget gauge)
  - Add budget alert to patrol
```

### Phase 1: This Week (6h total)

```
Day 1: Vulnerability scanning
  - Add daily scan cron
  - Build full Grafana dashboard (8 panels)
  - Pin all `latest` tags to specific versions

Day 2: Secret rotation
  - Create secret registry
  - Write rotation-check script
  - Wire into patrol
  - Set up Feishu alerts

Day 3: Token cost refinement
  - Tune budget limits based on first week of data
  - Add cost anomaly detection to patrol
```

### Phase 2: Next Week (8h total)

```
- Add token efficiency tracking (token-efficiency.md)
- Add fix age tracking to vuln scan pipeline
- Build cost-per-service CK tables (not dashboards yet)
- Add `kyb vuln` CLI subcommands
- Prune boss containers (save ~$11/mo)
```

### Phase 3: Next Month

```
- CI gates for vulnerability thresholds
- Automated secret rotation for Feishu token
- Cost-per-service Grafana dashboard
- Token efficiency optimization (prompt caching, tool selection)
```

---

## 5. What NOT to Do (Yet)

| Feature | Reason | When to Revisit |
|---------|--------|-----------------|
| **Cost-per-service Grafana dashboard** | $93/mo total infra cost is too low to justify the effort. The CK tables are useful for capacity planning but a dashboard is overkill. | When monthly infra cost exceeds $200 or we add a 4th cluster. |
| **CI gate blocking builds on CVEs** | Without a baseline, the first scan will flag hundreds of CVEs. Blocking builds would halt all work. Wait until ignore list stabilizes and fix pipelines are established. | After 2 weeks of scan data and a reviewed ignore list. |
| **In-sandbox token tracker (Mode A)** | Mode B (boss log tail) covers 95% of use cases with zero sandbox changes. Mode A adds accuracy for edge cases but costs complexity. | When we need per-sub-agent token breakdown or when Mode B misses >5% of turns. |
| **Full fix age algorithm** | Requires 2+ scans of the same image digest to compute diff. Running this before we have baseline data produces noise. | After Phase 1 scan data exists (1+ week of daily scans). |
| **Grype cross-check scanning** | Trivy covers the vulnerability DB adequately. Grype as a weekly cross-check adds complexity for marginal benefit. | Optional, only if a specific CVE is missed by Trivy. |
| **Automated secret rotation** | Rotating secrets programmatically is high risk (if the rotation script breaks, the secret is lost). Start with monitoring only. | When we have 3+ months of rotation data and a proven runbook. |
| **Cost forecasting (linear regression)** | Not enough historical data. Needs 3+ months of token cost and infra cost data. | After Phase 2 data collection. |

---

## 6. Alert Fatigue Risk Assessment

Adding 10+ alert rules across 3 initiatives risks alert fatigue. Here is the mitigation:

| Guard | How It Is Implemented |
|-------|----------------------|
| **Token cost alerts are per-project, not per-session** | Single project-level budget alert, not per-turn or per-session. Anomalous sessions (>$10) are P3 (quiet). |
| **Vuln scan alerts have 1h "for" duration** | Prometheus `for: 1h` prevents flapping. A CVE must persist for 1 hour before alerting. |
| **Secret rotation alerts have 1d grace** | `for: 1d` on rotation-overdue alerts allows in-progress rotations to complete without paging. |
| **Grace period for new deployments** | The vuln scan pipeline suppresses fix age alerts for the first 24h after initial deployment, avoiding a flood of "fix events" from baseline scans. |
| **Ignore lists** | Both vuln scan and secret rotation support explicit ignore entries with expiry dates. Reviewed weekly. |
| **Single notify channel** | All security alerts go to Feishu infra-security channel, not to individual pager duty. Only P0 goes to @all. |

**Expected daily alert volume after steady state:**

| Initiative | Daily Alerts (avg) | Daily Alerts (peak) |
|-----------|-------------------|-------------------|
| Token cost | 0 (budget not exceeded) | 1-2 (budget warning) |
| Vulnerability scanning | 0 (no new CVEs) | 1-3 (new critical CVE published) |
| Secret rotation | 0 (secrets within policy) | 1 (one secret approaching limit) |
| **Total** | **~0** | **3-5** |

Acceptable. No fatigue risk at these volumes.

---

## 7. Quick-Start Commands

### Token cost tracking

```bash
# Create tables
clickhouse-client -h 100.104.244.99 -q "
CREATE DATABASE IF NOT EXISTS infra;
CREATE TABLE IF NOT EXISTS infra.token_usage (...);  -- full schema in token-cost.md
CREATE TABLE IF NOT EXISTS infra.model_pricing (...);
CREATE TABLE IF NOT EXISTS infra.token_budgets (...);
"

# Seed pricing
clickhouse-client -h 100.104.244.99 -q "
INSERT INTO infra.model_pricing VALUES
  ('deepseek-v4-flash', 'deepseek', 0.35, 1.40, 0.07, 0.35, '2026-01-01', '9999-12-31'),
  ('claude-sonnet-4-7', 'anthropic', 3.00, 15.00, 0.30, 3.75, '2026-01-01', '9999-12-31'),
  ('claude-opus-4-7', 'anthropic', 15.00, 75.00, 1.50, 18.75, '2026-01-01', '9999-12-31');
"

# Deploy token tracker on boss
docker cp token-tracker.sh kyb-infra-boss:/usr/local/bin/token-tracker.sh
docker exec kyb-infra-boss bash -c "chmod +x /usr/local/bin/token-tracker.sh && nohup /usr/local/bin/token-tracker.sh &"
```

### Vulnerability scanning

```bash
# Deploy Trivy
docker pull aquasec/trivy:latest
docker volume create trivy-db

# Update DB
docker run --rm -v trivy-db:/home/trivy/.cache/trivy aquasec/trivy:latest image --download-db-only

# Scan all running images
docker ps --format '{{.Image}}' | sort -u | while read img; do
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-db:/home/trivy/.cache/trivy \
    aquasec/trivy:latest image --format json --severity CRITICAL,HIGH,MEDIUM "$img" \
    > "/tmp/vuln-$(echo $img | tr '/:@' '---').json"
done
```

### Secret rotation check

```bash
# Create registry
mkdir -p ~/.kyb/secrets
cat > ~/.kyb/secrets/registry.yml << 'EOF'
secrets:
  - name: feishu_app_token
    category: api
    environment: production
    last_rotated: "2026-01-17T10:00:00Z"
    rotation_policy_days: 90
    owner: infra-team
  - name: letsencrypt_boss
    category: tls
    environment: production
    last_rotated: "2026-03-15T00:00:00Z"
    expires_at: "2026-06-13T00:00:00Z"
    rotation_policy_days: 90
    owner: infra-team
EOF

# Run initial check
python3 ~/.kyb/bin/secret-rotation-check
```

---

> **Summary:** Token cost tracking and vulnerability scanning are P0 -- both deliver immediate value for low effort, and the infra currently has zero visibility into both. Secret rotation monitoring is P1 -- quick to set up, prevents silent outages. Infra cost-per-service and token efficiency are Phase 2 -- valuable but not urgent given current scale. The total Phase 0 effort is ~4 hours and should be completed in a single session.

> ／人◕ ‿‿ ◕人＼
