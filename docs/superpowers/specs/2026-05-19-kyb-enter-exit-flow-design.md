# kyb Enter Exit Flow Redesign

> Clean up after `kyb enter` — automatic idle detection, smart prompts, no surprise deletions.

## Current Problem

```
kyb enter  → docker exec → tmux → claude
                                         ↓
                                  user exits
                                         ↓
                            container keeps running (zombie)
```

- `exec` replaces the Ruby process — no chance for cleanup
- No mechanism to detect whether a container is still active
- Users accumulate stopped/idle containers without knowing which ones are live

## Design

### Exit Flow

```
宿主机                                    容器内
───────                                  ──────
kyb enter ── send-keys ──────────────→  tmux
                                                └→ kyb session wrap claude 'prompt'
                                                            ↓
                                                      claude 退
                                                            ↓
                                                      kyb session wrap 打印统计
                                                      "Still in tmux, type exit"
                                                            ↓
                                                      user exit → tmux dead
                                                            ↓
docker exec 返回
      ↓
3 项检查 → 全过 → [交互提示] → 自动清理
         → 有不过 → warn 原因，跳过
```

### 3 项 Idle Check

After `docker exec` returns, run these checks and report ALL results:

| Check | Fail → Warn | Action |
|-------|-------------|--------|
| tmux sessions | tmux still alive | skip cleanup |
| worktree dirty | uncommitted changes | skip cleanup |
| remote | unpushed commits | skip cleanup |

Additional warnings that do NOT block cleanup (shown in prompt):
- unexpected user processes beyond baseline (ps, postgres, sleep, entrypoint)
- DID child containers that will be cascade deleted

Output format:

```
━━━  Idle Check  ━━━
  ✔ tmux:     no active sessions
  ✔ worktree: clean
  ✔ remote:   all pushed
  ⚠  processes: node server.js
  ⚠  DID children: did-kyb-*-worktree
```

- All 3 checkmarks → proceed to interactive prompt
- Any ✗ → print warnings and exit, no cleanup

### Interactive Delete Prompt

Only when all 3 checks pass:

```
━━━  Container Idle  ━━━━━━━━━━━━━
Container:  kyb-kyb-dod    Up: 43m
Project:    kyb / dod
Session:    12m 34s         Cli: claude
Volume:     kyb-kyb-dod-claude  42MB
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Cleanup will:
  • stop & remove container
  • delete worktree & git branch kyb/kyb-dod
  • remove claude volume (42MB)
  • cascade delete DID children

Delete container? [y/N] (5s auto: skip)
```

Behavior:
- **Ctrl-C / Ctrl-D** → treated as "skip" (same as N/timeout)
- **timeout (5s)** → auto skip
- **y/Y** → full cleanup, print each step:
  ```
  ==> kyb-kyb-dod: stopping container
  ==> kyb-kyb-dod: removing container
  ==> worktree: removed
  ==> branch: kyb/kyb-dod deleted
  ==> volume: kyb-kyb-dod-claude removed (42MB freed)
  ==> Done.

      Start fresh: kyb create kyb-dod
  ```
- **n/N/timeout/Ctrl** → print:
  ```
  ==> Cleanup skipped.

      Delete manually: kyb rm kyb-dod
      Re-attach:       kyb enter kyb-dod
  ```

### `kyb session wrap <cli> [args]`

New subcommand, usable both inside and outside container.

**Purpose:** Wrap any CLI command, record session stats, print summary on exit.

**Behavior:**
1. Record `START_TIME`
2. `exec` the given CLI command
3. On CLI exit, print:

```
━━━ Session ━━━━━━━
Duration:  12m 34s
Command:   claude
────────────────────
Still inside tmux. Type 'exit' to close.
```

If the subcommand is run *outside* a tmux session, omit the "Type exit to close" line.

### `kyb enter` Changes

| Change | Reason |
|--------|--------|
| `exec` → `system` | Need control after docker exec returns |
| send-keys CLI → `kyb session wrap <cli> '...'` | Get session stats |
| Add cleanup flow after `system` returns | Idle check + prompt |

The send-keys command becomes:
```bash
cd ~/projects/<project> && mise trust && kyb session wrap claude '<prompt>'
```

### Interaction Matrix

| Exit path | tmux state | Behavior |
|-----------|-----------|----------|
| detach (Prefix+d) | alive | quiet exit, no prompt |
| session exit (type exit) | dead | 3 checks → all ✔ → prompt → cleanup |
| claude → session exit | dead | 3 checks → all ✔ → prompt → cleanup |
| Ctrl-C during prompt | — | treated as skip |

### Inside-vs-Outside `kyb session wrap`

The command works anywhere `kyb` is in PATH:
- **Host:** direct usage
- **Container:** kyb is available at `/home/dev/kyb/bin/kyb` (mounted ro via `kyb_repo` config). The entrypoint should add `/home/dev/kyb/bin` to PATH, or send-keys uses the full path.

### Files Changed

| File | Action |
|------|--------|
| `lib/kyb/cli/enter.rb` | exec → system, add idle check + cleanup flow |
| `lib/kyb/cli/session.rb` | NEW — `kyb session wrap` subcommand |
| `test/test_session.rb` | NEW — session wrap + idle check tests |
| `bin/kyb` | Register `session` subcommand |
| `entrypoint.sh` (optional) | Add /home/dev/kyb/bin to PATH if not already |

### Error Handling

- `kyb session wrap`: if CLI not found → print error, exit 1
- Idle check fails on docker exec → print error, skip cleanup
- Volume size stat fails → show "??" instead of size
- Git operations fail during cleanup → warn but continue

### Open Questions

- Should `kyb session wrap` support `--json` output for programmatic use? (Deferred)
- Detach detection: after `system()` returns, run `docker exec ... tmux has-session -t dev` — exit 0 = detach (session alive), exit 1 = session dead. Simple.
