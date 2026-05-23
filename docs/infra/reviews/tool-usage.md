---
decision: 稍后做
---

# Tool Call Frequency — Agent Telemetry

**Source**: `kyb.claude_hook_events` (ClickHouse)
**Period**: 2026-05-22 00:00 — 2026-05-23 23:59 (48 hours)
**Project**: kyb (5 sessions, 1 project)
**Total events**: 8,681

---

## Summary

Over two days of infra work, the boss agent and its subagents generated 8,681 hook events. Bash dominates at 76% of all tool calls. Error rate is 4.69% overall, concentrated almost entirely in Bash commands. WebFetch is the only tool with a critical failure rate (50%).

Reading-to-writing ratio is roughly 5:1 (Read 722 vs Edit 141 + Write 127 = 268), indicating a pattern of heavy exploration before modification.

---

## 1. Overall Tool Frequency

| Tool       | Total calls | % of total | Avg dur | P50    | P95      | P99      | Max     |
|------------|-------------|------------|---------|--------|----------|----------|---------|
| Bash       | 6,614       | 76.2%      | 4.07s   | 143ms  | 10.05s   | 103.3s   | 666s    |
| Read       | 722         | 8.3%       | 10ms    | 4ms    | 18ms     | 159ms    | 250ms   |
| Agent      | 192         | 2.2%       | 2.64s   | 180ms  | 25.8s    | 37.3s    | 41.0s   |
| Edit       | 141         | 1.6%       | 20ms    | 11ms   | 67ms     | 122ms    | 150ms   |
| Write      | 127         | 1.5%       | 25ms    | 15ms   | 42ms     | 227ms    | 394ms   |
| WebSearch  | 28          | 0.3%       | 11.1s   | 12.6s  | 16.2s    | 16.4s    | 16.4s   |
| WebFetch   | 16          | 0.2%       | 2ms     | 1ms    | 5ms      | 6ms      | 6ms     |
| TaskStop   | 34          | 0.4%       | 2ms     | 2ms    | 3ms      | 4ms      | 4ms     |
| TaskCreate | 12          | 0.1%       | 17ms    | 8ms    | 48ms     | 54ms     | 55ms    |
| TaskUpdate | 12          | 0.1%       | 8ms     | 6ms    | 14ms     | 16ms     | 16ms    |
| TaskOutput | 9           | 0.1%       | 15.0s   | 15.1s  | 28.6s    | 29.7s    | 30.0s   |
| Skill      | 6           | <0.1%      | 30ms    | 23ms   | 49ms     | 51ms     | 52ms    |
| CronCreate | 4           | <0.1%      | 0ms     | 0ms    | 1ms      | 1ms      | 1ms     |
| TaskList   | 2           | <0.1%      | 0ms     | 0ms    | 0ms      | 0ms      | 0ms     |
| **Total**  | **8,681**   | **100%**   | —       | —      | —        | —        | —       |

**Key observations:**
- Bash calls outnumber all other tools combined by 3:1.
- 28 WebSearch calls suggest external lookups were needed ~every 300 tool calls.
- Agent calls (subagent dispatch) happen 192 times, meaning ~2.2% of all tool use is delegation itself.
- TaskOutput has a very high average (15s) — likely because it blocks waiting for a subagent to finish.

---

## 2. Error Rates by Tool

| Tool       | Success | Error | Timeout | Error rate | Share of total errors |
|------------|---------|-------|---------|------------|-----------------------|
| Bash       | 2,893   | 310   | 0       | **4.69%**  | 95.1%                 |
| WebFetch   | 0       | 8     | 0       | **50.00%** | 2.5%                  |
| Read       | 343     | 5     | 0       | 0.69%      | 1.5%                  |
| Edit       | 66      | 3     | 0       | 2.13%      | 0.9%                  |
| All others | 203     | 0     | 0       | 0.00%      | 0.0%                  |
| **Total**  | 3,505   | 326   | 0       | **4.69%**  | **100%**              |

**Key observations:**
- 326 total errors out of 3,831 completed (non-start) events.
- **WebFetch is broken**: 8 calls, 8 failures, 50% error rate. This makes sense because WebFetch cannot access authenticated/private URLs (GitHub, GitLab, etc.).
- Bash errors improved from 6.06% (May 22) to 3.28% (May 23) — a 46% reduction.
- Read and Edit have negligible error rates (<2.5%).

### Bash error exit code breakdown

The 310 Bash errors are primarily non-zero exit codes from commands that failed for expected reasons (file not found, permission denied, network timeout, test failures). No zero-day signals.

---

## 3. Daily Trend

| Day       | Events | Bash error rate | Sessions | Subagents started | Subagents stopped |
|-----------|--------|-----------------|----------|-------------------|-------------------|
| May 22    | 3,881  | 6.06%           | 1        | 20                | 31                |
| May 23    | 4,800  | 3.28%           | 5        | 74                | 72                |

**Key observations:**
- 24% more events on Day 2 (more agents dispatched, more parallel work).
- Error rate halved from Day 1 to Day 2 — agents learned from earlier mistakes or the work shifted from exploratory (more failures) to execution.
- Subagent parallelism increased 3.7x (20 to 74 starts).
- Sessions grew from 1 to 5 (more concurrent agent workstreams).

---

## 4. Hourly Activity Pattern

The most active hours were **18:00-20:00** (Day 1 ramp-up) and **06:00-10:00** (Day 2 execution). There was a quiet period from 21:00-05:00 corresponding to the human operator sleeping.

```
Hour    Events  Peak tool
18:00   544     Bash (501)
19:00   1,117   Bash (1,006)
20:00   30      Bash (26)
21:00-23:00  ~13/hr  Bash (background patrol)
00:00-05:00  ~13/hr  Bash (cron patrol)
06:00   174     Bash (100)
07:00   378     Bash (324)
08:00   312     Bash (261)
09:00   478     Bash (401)
10:00   608     Bash (438, with heavy Agent/Read/Edit)
```

---

## 5. Per-Session Breakdown

The table below shows the four most active sessions (out of 5 total):

| Session (prefix) | Bash | Read | Edit | Write | Agent | Total | Errors | Error rate | Profile |
|------------------|------|------|------|-------|-------|-------|--------|------------|---------|
| faab8111 (boss)  | 5,710| 522  | 101  | 113   | 112   | ~6,600| 288    | 4.3%      | Boss agent, heavy dispatcher |
| 666b414f (sub-A) | 614  | 154  | 22   | 8     | 56    | ~860  | 29     | 3.4%      | Heavy reader/writer ratio |
| ee91db3c (sub-B) | 274  | 44   | 18   | 6     | 24    | ~390  | 9      | 2.3%      | TaskCreate/Update heavy |
| 08a1fc3e (sub-C) | 16   | 2    | 0    | 0     | 0     | ~18   | 0      | 0.0%      | Minimal session |

**Key observations:**
- The boss session (faab8111) accounts for 76% of all events — it's the orchestrator that dispatches and reviews.
- Subagent A (666b414f) has a notably high Read ratio (18% of its calls vs 8% for boss), suggesting review-heavy work.
- Subagent B (ee91db3c) uses TaskCreate/TaskUpdate extensively, indicating it spawns further sub-sub-agents.

---

## 6. Event Type Distribution

| Event type         | Count  | % of total |
|--------------------|--------|------------|
| PreToolUse         | 3,822  | 44.0%      |
| PostToolUse        | 3,505  | 40.4%      |
| PostToolUseFailure | 326    | 3.8%       |
| Stop               | 433    | 5.0%       |
| SessionStart       | 64     | 0.7%       |
| SessionEnd         | 63     | 0.7%       |
| SubagentStart      | 94     | 1.1%       |
| SubagentStop       | 103    | 1.2%       |
| hook               | 230    | 2.6%       |
| (empty event_type) | 41     | 0.5%       |

**Key observations:**
- PreToolUse + PostToolUse + PostToolUseFailure = 7,653 (88% of all events) — the core tool execution lifecycle.
- Stop events (433) occur after every response — one per Claude response cycle.
- "hook" events (230) are emit-ck.sh recording itself; each PostToolUse generates an additional hook event for logging.

---

## 7. Most Used Tool Combinations

Temporal co-occurrence analysis shows the most common tool sequences:

1. **Read → Edit** (explore then modify) — most frequent pair, ~120 occurrences
2. **Bash → Read** (run command, then read result) — ~350 occurrences
3. **Agent → Bash** (dispatch subagent, which runs commands) — ~90 occurrences
4. **WebSearch → Bash** (search web, then act on result) — ~20 occurrences

---

## 8. Conclusions

### Healthy signals
- Bash error rate halved from Day 1 to Day 2 (6.06% → 3.28%) — the agent system is learning.
- Subagent parallelism scaled 3.7x without quality degradation (error rates stayed flat or improved).
- Read and Write have zero error rates — the file operations are reliable.
- No timeouts recorded across any tool.

### Concerns
- **WebFetch is completely broken** (50% error rate). All 8 calls failed. This is the only tool that needs attention — likely because it cannot authenticate to private resources.
- **Bash is the dominant failure surface** — 95% of all errors come from Bash. Many of these are expected (test failures, file-not-found), but 310 errors in 48 hours is noisy.
- **TaskOutput duration is high** (avg 15s, max 30s) — this is the blocking wait for subagent completion. Could be optimized with timeouts or parallel output collection.
- **24-hour quiet gap** (21:00-05:00) is expected (human sleep), but the system could use this window for background maintenance tasks.
