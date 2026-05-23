---
decision: 稍后做
---

# Stale Branch Review

**Author**: boss
**Date**: 2026-05-23
**Scope**: All local and remote branches in the kyb repository

---

## Executive Summary

The repository has accumulated **85 branches** across local and remote namespaces. Of these, **55 remote branches** are fully merged into `master` and safe to delete immediately. **26 unmerged branches** require individual assessment. **3 local orphan branches** (no upstream) need cleanup.

**Recommended action**: Delete ~55 merged remote branches immediately. Archive or delete ~15 stale unmerged branches. Retain ~11 active branches.

---

## 1. Local Branches

### 1.1 Active (under active development)

| Branch | Ahead/Behind | Last Commit | Age | Notes |
|--------|-------------|-------------|-----|-------|
| `kyb/infra-boss-0523` | +44 / -0 | 2026-05-23 | ~0h | CURRENT, active now |
| `kyb/fix-init-flag` | +35 / -2 | 2026-05-23 | 6h | CURRENT branch, active |
| `kyb/fix-infra-docs` | +31 / -2 | 2026-05-23 | 7h | Recently active |
| `kyb/infra-handbooks` | +2 / -2 | 2026-05-23 | 11h | Recently active |

**Policy**: Keep. These are in-flight work.

### 1.2 Stale Orphans (no remote tracking)

| Branch | Ahead of Master | Last Commit | Age | Notes |
|--------|----------------|-------------|-----|-------|
| `kyb/diary-0523-night-watch` | ? | 2026-05-23 | 14h | Remote was pruned from origin |
| `kyb/fix-remove-method` | +5 | 2026-05-22 | 23h | Remote never pushed, same work as `kyb/fix-test-docker-containers` |
| `worktree-agent-a47433fc6685f2525` | +5 | 2026-05-22 | 23h | Worktree branch, same commit as above |

**Policy**: Delete. `kyb/fix-remove-method` and the worktree branch share a single commit (`463a8af8`) that is superseded by `origin/kyb/fix-test-docker-containers`. The diary branch's remote was already cleaned up on the server.

---

## 2. Remote Branches — Merged into Master (Safe to Delete)

**55 branches** are fully merged (`ahead:0`) and safe to purge. They are grouped by age (staleness tier).

### Tier 1: Stale (>2 days, 24 branches)

These are at least 2 days old with no unmerged commits. Likely abandoned after merge.

| Branch | Behind Master | Last Commit | Age |
|--------|--------------|-------------|-----|
| `kyb/kyb-build` | -252 | 2026-05-20 | 4 days |
| `kyb/update-mr-status` | -255 | 2026-05-20 | 4 days |
| `kyb/onboarded-projects-owner` | -261 | 2026-05-20 | 4 days |
| `kyb/kyb-fizzbuzz` | -220 | 2026-05-21 | 3 days |
| `kyb/onboarding-business-rule` | -198 | 2026-05-21 | 2 days |
| `kyb/wave-1-summary` | -197 | 2026-05-21 | 2 days |
| `kyb/scaling-pattern-doc` | -99 | 2026-05-21 | 2 days |
| `kyb/fix-onboard-agent-script` | -99 | 2026-05-21 | 2 days |
| `kyb/fix-ci-failures-1779387416` | -99 | 2026-05-21 | 2 days |
| `kyb/worldview-system` | -117 | 2026-05-22 | 2 days |
| `kyb/auto-metrics` | -113 | 2026-05-22 | 2 days |
| `kyb/fix-test-session-pollution` | -113 | 2026-05-22 | 2 days |
| `kyb/ci-test-parser-fix` | -109 | 2026-05-22 | 2 days |
| `kyb/ci-systemexit-fix` | -106 | 2026-05-22 | 2 days |
| `kyb/ci-proxy-docker-skip` | -100 | 2026-05-22 | 2 days |
| `kyb/ci-docker-guards` | -118 | 2026-05-22 | 2 days |
| `kyb/ci-fix-entrypoint` | -119 | 2026-05-22 | 2 days |
| `kyb/base-image-toolchain` | -142 | 2026-05-22 | 2 days |
| `kyb/issue-23-context` | -149 | 2026-05-22 | 2 days |
| `kyb/boss-mode-claude` | -154 | 2026-05-22 | 2 days |
| `kyb/tailscale-rules` | -154 | 2026-05-22 | 2 days |
| `kyb/file-layout-docs` | -167 | 2026-05-22 | 2 days |
| `kyb/issue-7-doctor` | -139 | 2026-05-22 | 2 days |
| `kyb/fix-reporter-teardown` | -123 | 2026-05-22 | 2 days |
| `kyb/fix-morning-test-placement` | -121 | 2026-05-22 | 2 days |
| `kyb/inline-comment-doc` | -99 | 2026-05-22 | 2 days |

### Tier 2: Fresh (<2 days, 29 branches)

Merged more recently. Still safe to delete but may be referenced in active discussions.

| Branch | Behind Master | Last Commit | Age |
|--------|--------------|-------------|-----|
| `kyb/cleanup-kyb-mounts` | -67 | 2026-05-23 | 25h |
| `kyb/docs-update` | -77 | 2026-05-23 | 26h |
| `kyb/fix-enter-cd` | -65 | 2026-05-23 | 25h |
| `kyb/fix-clone-path` | -71 | 2026-05-23 | 25h |
| `kyb/fix-infra-clone` | -73 | 2026-05-23 | 25h |
| `kyb/remove-tailscale-mount` | -75 | 2026-05-23 | 26h |
| `kyb/infra-boss` | -82 | 2026-05-23 | 26h |
| `kyb/fix-kyb-project` | -52 | 2026-05-23 | 25h |
| `kyb/fix-claude-short` | -53 | 2026-05-23 | 25h |
| `kyb/fix-claude-latest-path` | -55 | 2026-05-23 | 25h |
| `kyb/fix-infra-claude-path` | -57 | 2026-05-23 | 25h |
| `kyb/fix-ci-mirror` | -60 | 2026-05-23 | 25h |
| `kyb/fix-claude-postinstall` | -61 | 2026-05-23 | 25h |
| `kyb/fix-claude-boss` | -63 | 2026-05-23 | 25h |
| `kyb/fix-prompt-injection` | -98 | 2026-05-22 | 35h |
| `kyb/onboarding-template` | -285 | 2026-05-18 | 5 days |
| `docs/diary-2026-05-23` | -30 | 2026-05-23 | 22h |
| `docs/diary-step3` | -41 | 2026-05-23 | 23h |
| `docs/proxy-note` | -46 | 2026-05-23 | 23h |
| `docs/robustness-audit` | -32 | 2026-05-23 | 23h |
| `docs/robustness-workflow` | -19 | 2026-05-23 | 22h |
| `fix/branch-validation` | -43 | 2026-05-23 | 23h |
| `fix/check-backticks` | -13 | 2026-05-23 | 22h |
| `fix/morning-require` | -40 | 2026-05-23 | 23h |
| `fix/proxy-rescue` | -17 | 2026-05-23 | 22h |
| `fix/rescue-exception` | -28 | 2026-05-23 | 22h |
| `fix/rm-unused-constants` | -33 | 2026-05-23 | 23h |
| `fix/shell-injection-check` | -31 | 2026-05-23 | 23h |
| `fix/wire-doctor` | -48 | 2026-05-23 | 23h |

---

## 3. Remote Branches — Unmerged (Need Assessment)

### 3.1 Recently Active (likely keep)

| Branch | +/- | Last Commit | Age | Notes |
|--------|-----|-------------|-----|-------|
| `kyb/infra-boss-0523` | +44 / -0 | 2026-05-23 | ~0h | Active, in review |
| `kyb/fix-init-flag` | +35 / -2 | 2026-05-23 | 6h | Active |
| `kyb/fix-infra-docs` | +31 / -2 | 2026-05-23 | 7h | Active |
| `kyb/infra-handbooks` | +2 / -2 | 2026-05-23 | 11h | Active |
| `fix/proxy-env-docker-exec` | +1 / -2 | 2026-05-23 | 8h | Fresh, likely ready for merge |
| `fix/entrypoint-crash-exit-5` | +1 / -6 | 2026-05-23 | 12h | Fresh |
| `docs/diary-update` | +2 / -8 | 2026-05-23 | 14h | Fresh docs branch |
| `fix/config-atomic` | +3 / -8 | 2026-05-23 | 14h | Fresh fix |
| `fix/prune-confirm` | +3 / -8 | 2026-05-23 | 14h | Fresh fix |

**Policy**: Keep for now, merge or close within 48h.

### 3.2 Active (not yet merged, small delta)

| Branch | +/- | Last Commit | Age | Notes |
|--------|-----|-------------|-----|-------|
| `feat/sandbox-join-kyb-net` | +2 / -4 | 2026-05-23 | 11h | Feature branch, small behind |

**Policy**: Keep, merge soon.

### 3.3 Stale (>24h behind master by 50+ commits)

| Branch | +/- | Last Commit | Age | Notes |
|--------|-----|-------------|-----|-------|
| `fix/rm-remove-method` | +2 / -51 | 2026-05-22 | 23h | Likely superseded by `kyb/fix-test-docker-containers` |
| `fix/stale-ci-guard` | +2 / -51 | 2026-05-23 | 23h | Series of CI fix branches, all stale |
| `fix/stale-cli-consistency` | +2 / -51 | 2026-05-23 | 23h | Same series |
| `kyb/review-report-2026-05-23` | +1 / -51 | 2026-05-23 | 24h | Report branch |
| `kyb/fix-test-docker-containers` | +2 / -51 | 2026-05-22 | 23h | Test fix, may supersede `fix/rm-remove-method` |
| `kyb/fix-rm-cname` | +1 / -98 | 2026-05-22 | 28h | Small fix, very behind |
| `kyb/ci-final-fix-v2` | +1 / -99 | 2026-05-22 | 2 days | CI fix experiment |
| `kyb/ci-fix-cybernetics` | +1 / -99 | 2026-05-22 | 2 days | CI fix experiment |
| `kyb/ci-fix-empiricism` | +1 / -99 | 2026-05-22 | 2 days | CI fix experiment |
| `kyb/ci-fix-firstprinciples` | +1 / -99 | 2026-05-22 | 2 days | CI fix experiment |
| `kyb/ci-fix-pragmatism` | +1 / -99 | 2026-05-22 | 2 days | CI fix experiment |
| `kyb/ci-fix-v2` | +4 / -107 | 2026-05-22 | 2 days | CI fix experiment |
| `kyb/progress-summary` | +4 / -107 | 2026-05-22 | 2 days | Summary branch |
| `kyb/issue-18-rm-confirmation` | +1 / -135 | 2026-05-22 | 2 days | Issue branch, very behind |
| `kyb/issue-cli-batch` | +1 / -141 | 2026-05-22 | 2 days | Issue branch, very behind |
| `kyb/morning-command` | +1 / -125 | 2026-05-22 | 2 days | Stale experiment |
| `kyb/new-machine-onboarding` | +46 / -232 | 2026-05-21 | 3 days | Old, very behind — likely superseded |

**Policy**: Flag for deletion. These branches:
  - Have 0-4 commits of their own
  - Are 50-232 commits behind master
  - Have no open MRs associated with them
  - Are likely experimental/superseded branches

---

## 4. Cleanup Policy

### 4.1 Tier Definitions

| Tier | Criteria | Action | Auto-Cleanup After |
|------|----------|--------|-------------------|
| **Active** | Last commit <24h, OR has open MR | Keep | N/A |
| **Stale** | Merged AND last commit >48h | Delete remote | 48h post-merge |
| **Orphaned** | No upstream, or upstream deleted | Delete local | Immediately |
| **Zombie** | Unmerged, behind master >50 commits, no MR, age >48h | Flag for review | 7d then delete |
| **Experiment** | CI experiment / spike branches | Delete remote | Immediately after experiment ends |

### 4.2 Enforcement

1. **Post-merge hook**: Automatically delete the source branch when a MR is merged in GitLab (enabled in GitLab project settings).
2. **Weekly review**: Boss runs `git branch -r --merged origin/master` weekly and bulk-deletes Tier 2+ branches.
3. **Branch naming**: Use `feat/` or `fix/` prefixes for work that must be merged. Use `wip/` or `exp/` for experiments (auto-cleanup after 48h).
4. **Local branches**: Run `git fetch --prune` regularly. Delete local branches whose remote was pruned.

### 4.3 Cleanup Commands

```bash
# Prune remote refs
git fetch origin --prune

# Delete merged remote branches (Tier 1)
git push origin --delete \
  kyb/base-image-toolchain kyb/kyb-build kyb/update-mr-status \
  kyb/onboarded-projects-owner kyb/kyb-fizzbuzz \
  kyb/onboarding-business-rule kyb/wave-1-summary \
  kyb/scaling-pattern-doc kyb/fix-onboard-agent-script \
  kyb/fix-ci-failures-1779387416 kyb/worldview-system \
  kyb/auto-metrics kyb/fix-test-session-pollution \
  kyb/ci-test-parser-fix kyb/ci-systemexit-fix \
  kyb/ci-proxy-docker-skip kyb/ci-docker-guards \
  kyb/ci-fix-entrypoint kyb/issue-23-context \
  kyb/boss-mode-claude kyb/tailscale-rules \
  kyb/file-layout-docs kyb/issue-7-doctor \
  kyb/fix-reporter-teardown kyb/fix-morning-test-placement \
  kyb/inline-comment-doc

# Delete stale unmerged experiment branches
git push origin --delete \
  kyb/ci-final-fix-v2 kyb/ci-fix-cybernetics kyb/ci-fix-empiricism \
  kyb/ci-fix-firstprinciples kyb/ci-fix-pragmatism kyb/ci-fix-v2 \
  kyb/progress-summary kyb/issue-18-rm-confirmation \
  kyb/issue-cli-batch kyb/morning-command \
  kyb/new-machine-onboarding kyb/fix-rm-cname

# Delete local orphan branches
git branch -D kyb/fix-remove-method
git branch -D worktree-agent-a47433fc6685f2525
git branch -D kyb/diary-0523-night-watch
```

---

## 5. Current Summary

| Category | Count |
|----------|-------|
| Local active branches | 4 |
| Local orphan branches (delete) | 3 |
| Remote merged (delete) | 55 |
| Remote unmerged recently active (keep) | 10 |
| Remote unmerged stale (review -> probably delete) | 16 |
| **Total** | **88** |

Running total after cleanup: ~14 branches (4 local + 10 unmerged keep).

---

## 6. Recommendations

1. **Immediate**: Delete all 55 merged remote branches (low risk).
2. **Immediate**: Delete 16 stale unmerged experiment branches.
3. **Immediate**: Delete 3 local orphan branches.
4. **Today**: Merge the 10 active unmerged branches (or close them).
5. **Configuration**: Enable "Delete source branch" in GitLab project settings for all future MR merges.
6. **Habit**: Run `git fetch --prune && git branch -vv | grep ': gone]' | awk '{print $1}' | xargs git branch -D` weekly.
