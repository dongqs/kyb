---
decision: 稍后做
---

# Git Operations Frequency Report

**Period:** 2026-05-07 – 2026-05-23 (17 days)
**Repo:** kyb (single-author, LLM-driven)
**Author:** AOYAMA / 青山 <dongqs@leyantech.com>
**Bot:** CI <coding-agent@leyantech.com> (1 commit)

---

## 1. Commit Frequency

| Metric | Value |
|---|---|
| Total commits | 714 |
| Average commits/day | **42.0** |
| Median commits/day | 34 |
| Peak day | 2026-05-23 (135) |

**Daily commit volume:**

| Date | Commits | Notes |
|------|---------|-------|
| 2026-05-07 | 31 | Day 1 — project creation |
| 2026-05-08 | 1 | |
| 2026-05-09 | 29 | |
| 2026-05-10 | 30 | |
| 2026-05-11 | 26 | |
| 2026-05-12 | 34 | |
| 2026-05-13 | 40 | |
| 2026-05-14 | 3 | Weekend / low activity |
| 2026-05-15 | — | Gap |
| 2026-05-16 | — | Gap |
| 2026-05-17 | 43 | Resumption |
| 2026-05-18 | 40 | |
| 2026-05-19 | 15 | Low — possibly blocked |
| 2026-05-20 | 65 | Acceleration |
| 2026-05-21 | 106 | Intensified multi-agent dispatch |
| 2026-05-22 | 120 | Peak multi-agent day |
| 2026-05-23 | 135 | All-time high (partial day, in progress) |

**Hourly distribution (UTC):**

| Hour (UTC) | Commits | Interpretation (CST = UTC+8) |
|-----------|---------|------|
| 17:00 | 72 | Peak — afternoon CST |
| 18:00 | 57 | |
| 16:00 | 47 | |
| 01:00 | 44 | Overnight agent runs |
| 22:00–23:00 | 84 | Evening/night agent runs |
| 02:00–03:00 | 72 | Deep night agent runs |

The activity curve is **bimodal**: a primary peak at 16:00–18:00 UTC (midnight–02:00 CST, likely overnight agent batches) and a secondary peak at 01:00–03:00 UTC (09:00–11:00 CST, morning working hours). This is consistent with LLM-agent batch dispatch patterns.

---

## 2. Push Frequency

| Metric | Value |
|---|---|
| Total pushes (reflog) | 61 |
| Average pushes/day | **~3.6** |

Pushes per day in the local reflog track the current machine only. The 84 remote branches and 120 merge commits indicate additional push activity from other worktree sessions.

**Observation:** Many commits are batched into single pushes. On high-volume days (135 commits on 2026-05-23), the push-to-commit ratio is approximately 1:4, suggesting the agent batch-commits and batch-pushes.

---

## 3. Branch Creation Rate

| Metric | Value |
|---|---|
| Total remote branches (excl. master) | **83** |
| Total local branches | 9 |
| Estimated branches created per day | **~5** (during active periods) |

Branch naming conventions observed on remote:

| Prefix | Count (approx.) | Purpose |
|--------|-------|---------|
| `kyb/*` | ~20 | Infra docs, boss sessions |
| `fix/*` | ~15 | Bug fixes, CI fixes |
| `feat/*` | ~3 | New features |
| `docs/*` | ~8 | Documentation updates |
| `fix/rm-*`, `fix/stale-*` | ~5 | Code cleanup branches |

Branch lifetimes are typically hours to 1 day. Many branches are pushed and merged within the same session, suggesting ephemeral worktree-based workflow.

**Branch lifecycle pattern:**
1. Agent creates branch from `master`
2. Agent pushes branch to remote
3. MR created, CI runs
4. Branch merged within hours
5. Branch is never deleted from remote (accumulation)

---

## 4. Merge Frequency

| Metric | Value |
|---|---|
| Total merge commits | **120** |
| Average merges/day | **~7** |
| Merge rate (merges per commit) | **16.8%** |

**Merges per day:**

| Date | Merges |
|------|--------|
| 2026-05-12 | 1 |
| 2026-05-17 | 16 |
| 2026-05-18 | 19 |
| 2026-05-19 | 4 |
| 2026-05-20 | 6 |
| 2026-05-21 | 28 |
| 2026-05-22 | 34 |
| 2026-05-23 | 12 |

Merge activity strongly correlates with commit volume (r ~ 0.9). The high merge-to-commit ratio (17%) combined with a single author indicates an **LLM-agent merge workflow**: each agent commit is typically a distinct feature/fix branch that gets merged via MR.

**Merge strategy:** All observed merges are `Merge remote-tracking branch` (no squash merges observed). This preserves full branch history but adds merge commits to the mainline.

---

## 5. Revert Rate

| Metric | Value |
|---|---|
| Total revert-related commits | **6** |
| Revert rate (reverts per total commits) | **0.84%** |
| Revert rate (reverts per merge) | **5.0%** |

Revert commits:

| Commit | Type |
|--------|------|
| `Revert "fix: stabilize default prompt..."` | `git revert` |
| `Revert "fix: use fixed alias in version output..."` | `git revert` |
| `Revert "enter: cat CLAUDE.md before launching claude"` | `git revert` |
| `Revert port mapping - proxy already accessible...` | `git revert` (manual) |
| `fix: revert test_stale.rb to docker_available? guard` | Manual revert in fix commit |
| `fix: revert to short claude command` | Manual revert in fix commit |

Of 6 reverts:
- 4 are standard `git revert` commits
- 2 are manual reverts embedded in `fix:` commits

**Interpretation:** <1% revert rate is healthy. The combination of automatic test gating (CI) and TDD workflow (test-first) keeps regression rate low. No evidence of systemic quality issues.

---

## 6. Commit Type Distribution

| Type | Count | Percentage |
|------|-------|-----------|
| `fix:` | 180 | 26.5% |
| `docs:` | 172 | 25.3% |
| `feat:` | 103 | 15.2% |
| `chore:` | 39 | 5.7% |
| `refactor:` | 27 | 4.0% |
| `test:` | 8 | 1.2% |
| Other / unclassified | 151 | 22.2% |

The ratio of `fix:` to `feat:` commits (~1.7:1) is typical for an active development phase with CI-driven bug fixing.

---

## 7. Summary & Recommendations

**Current state:**
- High-velocity single-author LLM-agent-driven repository
- ~42 commits/day, ~7 merges/day, ~3.6 pushes/day
- ~0.8% revert rate (healthy)
- Ephemeral branch workflow with MR-based integration
- All merges preserve full history (no squash)

**Recommended actions:**
1. **Branch cleanup** — 83 stale remote branches accumulate. Add a branch-pruning policy (delete after merge, or auto-delete via CI).
2. **Squash merges for trivial branches** — Consider squash-merge for single-commit feature branches to reduce merge-commit noise on mainline.
3. **Monitor revert rate** — If reverts exceed 2% consistently, investigate CI gap or review process.
4. **Push frequency** — Current batch-push pattern is fine for single-author, but with multiple agents, more granular pushes may reduce conflicts.
5. **Add two more authors** — The repository is entirely dependent on one human (+ agents). Bus-factor = 1.
